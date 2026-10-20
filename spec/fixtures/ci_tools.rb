# frozen_string_literal: true
# Model the external Git/Docker/export interfaces without building product images.
require 'fileutils'
require 'json'
require 'open3'
tool = File.basename($PROGRAM_NAME)
File.open(ENV.fetch('SKVOZ_CI_TEST_LOG'), 'a') { |log| log.puts(JSON.generate([tool, *ARGV])) }
case tool
when 'git'
  case ARGV.first
  when 'rev-parse' then puts ENV.fetch('GITHUB_SHA')
  when 'status' then puts ' M README.md' if ENV['SKVOZ_CI_TEST_DIRTY'] == '1'
  when 'archive'
    exec('tar', '-cf', '-', '-T', '/dev/null')
  else abort 'Unexpected Git command'
  end
when 'docker'
  if ARGV.first == 'run'
    target = ARGV.find { |argument| argument.start_with?('skvoz-server:ci-') }
    exit 17 if ARGV.include?('rspec') && target == ENV['SKVOZ_CI_TEST_FAILURE']
    if ARGV.include?('/native-lock.json')
      destination = ARGV.find { |argument| argument.end_with?(',dst=/download') }
      root = destination.delete_prefix('type=bind,src=').delete_suffix(',dst=/download')
      File.write(File.join(root, File.basename(ARGV.last)), 'ready pinned Network fixture')
    end
  elsif ARGV.take(2) == %w[image inspect]
    puts 'sha256:' + 'b' * 64
  elsif ARGV.first == 'build'
    target = ARGV[ARGV.index('--target') + 1]
    if target != 'ruby-tests'
      archive = File.join(ARGV.last, 'artifacts/native/skvoz-network-0.7.0-x86_64-unknown-linux-gnu-current-identity.tar.gz')
      abort 'Native archive was not prepared before the build' unless File.file?(archive)
    end
  elsif ARGV.take(2) != %w[rm -f]
    abort 'Unexpected Docker command'
  end
when 'ruby'
  abort 'Unexpected export arguments' unless ARGV.take(2) == ['bin/export-image', '--revision'] && ARGV[2] == ENV.fetch('GITHUB_SHA')
  FileUtils.mkdir_p(ARGV.last)
  File.write(File.join(ARGV.last, 'exported'), ARGV[3])
else
  abort 'Unexpected tool'
end
