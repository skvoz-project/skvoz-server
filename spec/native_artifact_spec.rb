# frozen_string_literal: true
require_relative 'spec_helper'
require_relative 'support/system'
require 'digest'
require 'rubygems/package'
require 'zlib'

RSpec.describe 'Server pinned Network archive' do
  include ServerSystem

  around do |example|
    Dir.mktmpdir('skvoz-network-extract-') do |directory|
      @directory = directory
      @destination = File.join(directory, 'install with spaces')
      @archive = File.join(directory, 'bundle with spaces.tar.gz')
      @lock = File.join(directory, 'lock.json')
      @files = %w[bin/skvoz-network-runtime bin/skvoz-network-helper lib/libskvoz_core.so
        resources/systemd/skvoz-network-helper@.socket resources/systemd/skvoz-network-helper@.service
        resources/systemd/skvoz-network-helper.conf resources/polkit/org.skvoz.network.policy
        licenses/Network-MIT.txt licenses/Core-MIT.txt licenses/async-nats-Apache-2.0.txt source-inputs.sha256 manifest.json]
      example.run
    end
  end

  def bundle(files = @files)
    Zlib::GzipWriter.open(@archive) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        files.each { |path| tar.add_file_simple(path, 0o644, path.bytesize) { |entry| entry.write(path) } }
        tar.add_file_simple('bin/unneeded-tool', 0o755, 6) { |entry| entry.write('unused') }
      end
    end
    File.write(@lock, JSON.generate(artifact: { url: 'file:bundle%20with%20spaces.tar.gz', sha256: Digest::SHA256.file(@archive).hexdigest }))
  end

  def install(local = true)
    argv = [RbConfig.ruby, ServerSystem::COMPONENT.join('bin/install-native'), @lock, @destination]
    argv << @archive if local
    capture('sh', '-c', 'umask 077; exec "$@"', 'sh', *argv, timeout: 15)
  end

  it 'verifies pinned bytes and extracts only required files without a supplier executable' do
    bundle
    _, error, status = install(false)
    expect(status.success?).to be(true), error
    @files.each do |name|
      path = File.join(@destination, name)
      expect(File.binread(path)).to eq(name)
      expect(File.stat(path).mode & 0o777).to eq(name.start_with?('bin/') ? 0o755 : 0o644)
    end
    expect(File.exist?(File.join(@destination, 'bin/unneeded-tool'))).to be(false)
    expect(File.stat(File.join(@destination, 'lib')).mode & 0o777).to eq(0o755)
  end

  it 'rejects changed archive bytes before extraction and preserves existing destinations' do
    bundle
    File.open(@archive, 'ab') { |file| file.write('changed') }
    _, error, status = install
    expect(status.success?).to be(false)
    expect(error).to include('checksum')
    expect(File.exist?(@destination)).to be(false)
    File.write(@destination, 'owned')
    expect(install.last.success?).to be(false)
    expect(File.read(@destination)).to eq('owned')
  end

  it 'does not publish partial output for missing or duplicate required files' do
    [@files - ['lib/libskvoz_core.so'], @files + ['lib/libskvoz_core.so']].each do |files|
      bundle(files)
      expect(install.last.success?).to be(false)
      expect(File.exist?(@destination)).to be(false)
      expect(Dir.glob(File.join(@directory, '.skvoz-native-*'))).to be_empty
    end
  end
end
