# frozen_string_literal: true
require_relative 'spec_helper'
require_relative 'support/system'

RSpec.describe 'Owning Server temporary lifecycle', integration: true do
  include ServerSystem

  def with_fixture(ports: [], lifetime: 300, finish: :eof)
    input = output = error = process = nil
    Dir.mktmpdir('skvoz-fixture-consumer-') do |directory|
      log = File.join(directory, 'fixture.log')
      input, output, error, process = Open3.popen3(RbConfig.ruby,
        ServerSystem::COMPONENT.join('spec/fixtures/server_fixture.rb').to_s, '--lifetime', lifetime.to_s,
        *ports.flat_map { |port| ['--allow-loopback-port', port.to_s] })
      drain = Thread.new { File.open(log, 'wb') { |file| IO.copy_stream(error, file) } }
      bytes = Timeout.timeout(60) { output.gets("\n", 65_537) }
      unless bytes
        drain.join(2)
        raise IOError, "Fixture exited before readiness: #{File.read(log)}"
      end
      expect(bytes.bytesize).to be <= 65_536
      metadata = JSON.parse(bytes, allow_duplicate_key: false)
      expect(metadata).to include('v' => 1, 'deadline_seconds' => lifetime)
      fixture_directory = File.dirname(metadata.fetch('config'))
      yield metadata, Pathname.new(directory) if block_given?
      case finish
      when :eof then input.close
      when :term then Process.kill('TERM', process.pid)
      when :int then Process.kill('INT', process.pid)
      when :deadline then nil
      end
      status = Timeout.timeout(lifetime == 1 ? 25 : 20) { process.value }
      expect(status.success?).to be(true), File.read(log)
      expect(File.exist?(fixture_directory)).to be(false)
    ensure
      input&.close unless input&.closed?
      if process&.alive?
        Process.kill('TERM', process.pid) rescue Errno::ESRCH
        process.join(20) || (Process.kill('KILL', process.pid) rescue Errno::ESRCH)
        process.join(5)
      end
      output&.close
      drain&.join(2)
      error&.close
    end
  end

  it 'rejects invalid ports and a ninth distinct port before starting a server' do
    [[0], [65_536], (1..9).to_a].each do |ports|
      _, _, status = capture(RbConfig.ruby, ServerSystem::COMPONENT.join('spec/fixtures/server_fixture.rb'),
        *ports.flat_map { |port| ['--allow-loopback-port', port] }, timeout: 5)
      expect(status.success?).to be(false)
    end
  end

  it 'denies default destinations and removes its state and processes on stdin EOF' do
    target = ServerSystem::Target.new { |socket| after_fin(socket) }
    with_fixture do |metadata, directory|
      device = ServerSystem::Device.new(directory.join('device'), metadata.fetch('bundle'))
      expect { device.path.open('127.0.0.1', target.port) }.to raise_error(IOError, 'forbidden')
    ensure
      device&.close
    end
  ensure
    target&.close
  end

  it 'admits eight exact ports with repeats and carries IPv4/IPv6 bytes after FIN' do
    ipv4 = ServerSystem::Target.new { |socket| after_fin(socket) }
    ipv6 = ServerSystem::Target.new(host: '::1') { |socket| after_fin(socket) }
    ports = [ipv4.port, ipv6.port, *free_ports(6, except: [ipv4.port, ipv6.port])]
    with_fixture(ports: ports + [ipv4.port]) do |metadata, directory|
      rules = JSON.parse(File.read(metadata.fetch('config'))).fetch('allow')
      expect(rules.map { |rule| rule.fetch('cidr') }).to eq(%w[127.0.0.1/32 ::1/128])
      expect(rules.map { |rule| rule.fetch('ports') }).to eq([ports, ports])
      device = ServerSystem::Device.new(directory.join('device'), metadata.fetch('bundle'))
      expect(transfer(device.path, ipv4.port, 'ipv4')).to eq('after-fin:4vpi')
      expect(transfer(device.path, ipv6.port, 'ipv6', host: '::1')).to eq('after-fin:6vpi')
      stdout, _, status = capture(*metadata.fetch('cli'), 'health', '--state', metadata.fetch('state'))
      expect(status.success? && JSON.parse(stdout).fetch('healthy')).to be(true)
    ensure
      device&.close
    end
  ensure
    ipv4&.close
    ipv6&.close
  end

  it 'admits one selected loopback port and denies another owned destination' do
    allowed = ServerSystem::Target.new { |socket| after_fin(socket) }
    denied = ServerSystem::Target.new { |socket| after_fin(socket) }
    with_fixture(ports: [allowed.port]) do |metadata, directory|
      device = ServerSystem::Device.new(directory.join('device'), metadata.fetch('bundle'))
      expect(transfer(device.path, allowed.port, 'selected')).to eq('after-fin:detceles')
      expect { device.path.open('127.0.0.1', denied.port) }.to raise_error(IOError, 'forbidden')
    ensure
      device&.close
    end
  ensure
    allowed&.close
    denied&.close
  end

  %i[term int deadline].each do |finish|
    it "cleans up after #{finish}" do
      with_fixture(lifetime: finish == :deadline ? 1 : 300, finish:)
    end
  end
end
