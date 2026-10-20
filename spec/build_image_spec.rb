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
