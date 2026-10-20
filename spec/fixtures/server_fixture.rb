#!/usr/bin/env ruby
# frozen_string_literal: true
abort 'Ruby 4.0.7 is required' unless RUBY_VERSION == '4.0.7'
require 'bundler/setup'
require 'optparse'
require 'tmpdir'
require_relative '../support/system'

options = { lifetime: 300, ports: [] }
OptionParser.new do |parser|
  parser.banner = 'Usage: server-fixture [--lifetime SECONDS] [--allow-loopback-port PORT]'
  parser.on('--lifetime SECONDS', Integer) { |value| options[:lifetime] = value }
  parser.on('--allow-loopback-port PORT', Integer) do |port|
    abort 'Invalid loopback port' unless port.between?(1, 65_535)
    options[:ports] << port unless options[:ports].include?(port)
    abort 'Loopback port budget exceeded' if options[:ports].size > 8
  end
end.parse!
abort 'Invalid fixture lifetime' unless ARGV.empty? && options[:lifetime].between?(1, 3600)
abort 'Run the fixture as an unprivileged user' if Process.euid.zero?
STDOUT.sync = true
Dir.mktmpdir('skvoz-server-fixture-') do |directory|
  server = nil
  reader, writer = IO.pipe
  previous = %w[INT TERM].to_h { |signal| [signal, Signal.trap(signal) { writer.write_nonblock('x', exception: false) }] }
  begin
    File.chmod(0o700, directory)
    allow = options[:ports].empty? ? [] : %w[127.0.0.1/32 ::1/128].map do |cidr|
      { 'cidr' => cidr, 'protocols' => [6], 'ports' => options[:ports] }
    end
    bundle = Timeout.timeout(60) do
      ServerSystem.certificates(directory)
      server = ServerSystem::Server.new(directory, allow:)
      server.command('add', 'fixture')
    end
    metadata = { v: 1, bundle: bundle, state: server.state.to_s, config: server.config.to_s,
      cli: [RbConfig.ruby, ServerSystem::COMPONENT.join('bin/skvoz-server').to_s],
      deadline_seconds: options[:lifetime] }
    bytes = JSON.generate(metadata)
    raise IOError, 'Fixture metadata exceeds limit' if bytes.bytesize > 65_536
    puts bytes
    ready = IO.select([STDIN, reader], nil, nil, options[:lifetime])
    if ready && ready.first.include?(STDIN)
      input = STDIN.read_nonblock(1, exception: false)
      raise ArgumentError, 'Fixture stdin accepts no commands' unless input.nil? || input == :wait_readable
    end
  ensure
    previous.each { |signal, handler| Signal.trap(signal, handler) }
    server&.close
    reader.close
    writer.close
  end
end
