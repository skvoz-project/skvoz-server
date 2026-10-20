# frozen_string_literal: true
require_relative 'spec_helper'
require_relative 'support/system'
require 'shellwords'

RSpec.describe 'Server image build entrypoint' do
  include ServerSystem

  it 'requires a reviewed prepared builder and owning output before invoking Docker' do
    Dir.mktmpdir('skvoz-build-rejection-') do |directory|
      marker = File.join(directory, 'docker.called')
      docker = File.join(directory, 'docker')
      File.write(docker, "#!/bin/sh\n: > #{Shellwords.escape(marker)}\nexit 0\n")
      File.chmod(0o755, docker)
      _, _, status = capture('/bin/sh', ServerSystem::COMPONENT.join('bin/build-image'), 'deploy', 'skvoz-server:test',
        env: { 'PATH' => directory + ':' + ENV.fetch('PATH'), 'SKVOZ_BUILDKIT_CONTAINER' => nil, 'SKVOZ_BUILD_OUTPUT' => nil }, timeout: 5)
      expect(status.success?).to be(false)
      expect(File.exist?(marker)).to be(false)
    end
  end

  it 'rejects a different daemon image before invoking buildctl or loading output' do
    Dir.mktmpdir('skvoz-build-identity-') do |directory|
      calls = File.join(directory, 'calls')
      docker = File.join(directory, 'docker')
      File.write(docker, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> #{Shellwords.escape(calls)}\nprintf '%s\\n' '#{'a' * 64} wrong-image true'\n")
      File.chmod(0o755, docker)
      _, error, status = capture('/bin/sh', ServerSystem::COMPONENT.join('bin/build-image'), 'deploy', 'skvoz-server:test',
        env: { 'PATH' => directory + ':' + ENV.fetch('PATH'), 'SKVOZ_BUILDKIT_CONTAINER' => 'owned-builder', 'SKVOZ_BUILD_OUTPUT' => directory }, timeout: 5)
      expect(status.success?).to be(false)
      expect(error).to include('identity differs')
      expect(File.readlines(calls).length).to eq(1)
      expect(File.read(calls)).to start_with('container inspect ')
    end
  end
end

RSpec.describe 'GitHub Server build flow' do
  include ServerSystem

  def run_ci(directory, failure: nil, dirty: false)
    tools = File.join(directory, 'tools')
    Dir.mkdir(tools)
    source = ServerSystem::COMPONENT.join('spec/fixtures/ci_tools.rb')
    %w[git docker ruby].each do |name|
      File.write(File.join(tools, name), "#!#{RbConfig.ruby}\n" + File.read(source))
      File.chmod(0o755, File.join(tools, name))
    end
    capture('bash', ServerSystem::COMPONENT.join('bin/ci'),
      env: { 'PATH' => tools + ':' + ENV.fetch('PATH'), 'CI' => 'true', 'GITHUB_SHA' => 'a' * 40,
        'RUNNER_TEMP' => directory, 'SKVOZ_CI_TEST_LOG' => File.join(directory, 'calls'),
        'SKVOZ_CI_TEST_FAILURE' => failure, 'SKVOZ_CI_TEST_DIRTY' => dirty ? '1' : nil }, timeout: 5)
  end

  it 'builds and tests with ready Network input and exports without local machine probes' do
    Dir.mktmpdir('skvoz-ci-flow-') do |directory|
      _, error, status = run_ci(directory)
      expect(status.success?).to be(true), error
      expect(File.read(File.join(directory, 'server-image/exported'))).to eq('sha256:' + 'b' * 64)
      calls = File.readlines(File.join(directory, 'calls')).map { |line| JSON.parse(line) }
      builds = calls.select { |tool, operation, *| tool == 'docker' && operation == 'build' }
      expect(builds.map { |args| args[args.index('--target') + 1] }).to eq(%w[ruby-tests tests deploy])
      expect(calls.flatten).not_to include('--device-read-bps', '--privileged', 'buildctl')
      expect(Dir.glob(File.join(directory, 'skvoz-server-ci.*'))).to be_empty
    end
  end

  it 'stops on failing tests, cleans up and never exports a product' do
    %w[ruby-tests tests].each do |target|
      Dir.mktmpdir('skvoz-ci-failure-') do |directory|
        _, _, status = run_ci(directory, failure: "skvoz-server:ci-#{target}")
        expect(status.exitstatus).to eq(17)
        expect(File.exist?(File.join(directory, 'server-image'))).to be(false)
        expect(Dir.glob(File.join(directory, 'skvoz-server-ci.*'))).to be_empty
      end
    end
  end

  it 'rejects a dirty source tree before invoking Docker' do
    Dir.mktmpdir('skvoz-ci-dirty-') do |directory|
      _, _, status = run_ci(directory, dirty: true)
      expect(status.success?).to be(false)
      calls = File.readlines(File.join(directory, 'calls')).map { |line| JSON.parse(line) }
      expect(calls.none? { |call| call.first == 'docker' }).to be(true)
    end
  end
end
