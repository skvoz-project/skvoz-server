# frozen_string_literal: true
require_relative 'spec_helper'
load File.expand_path('../bin/publish-image', __dir__)

RSpec.describe ServerImageRelease do
  around do |example|
    Dir.mktmpdir('skvoz-image-release-') do |directory|
      @directory, @root = directory, File.join(directory, 'checkout')
      @revision = 'a' * 40
      @environment = { 'GITHUB_REPOSITORY' => ServerImage::REPOSITORY, 'GITHUB_EVENT_NAME' => 'push',
        'GITHUB_REF' => 'refs/heads/main', 'GITHUB_SHA' => @revision }
      @release = described_class.new(@root, directory, @environment)
      @commands = []
      @dirty = @exists = @api_failure = @tag_failure = false
      @receipt = { 'schema' => 1, 'component' => 'skvoz-server', 'version' => '8.0.1',
        'target' => 'x86_64-unknown-linux-gnu', 'source' => { 'repository' => ServerImage::SOURCE, 'revision' => @revision },
        'image_id' => 'sha256:' + 'b' * 64, 'tag' => "server-v8.0.1-#{@revision}" }
      package
      example.run
    end
  end

  before do
    status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
    allow(Open3).to receive(:capture3) do |*argv|
      @commands << argv
      command = argv.drop(3)
      if command.first == 'git'
        [command.include?('rev-parse') ? @revision + "\n" : (@dirty ? ' M README.md' : ''), '', status.new(0)]
      elsif command[0, 2] == %w[gh api] && command.include?('POST')
        ['', '', status.new(@tag_failure ? 1 : 0)]
      elsif command[0, 2] == %w[gh api]
        [@exists ? 'HTTP/2.0 200 OK' : 'HTTP/2.0 404 Not Found', '', status.new(@api_failure ? 2 : (@exists ? 0 : 1))]
      else
        ['', '', status.new(0)]
      end
    end
  end

  def package
    File.binwrite(File.join(@directory, ServerImage::ASSET), 'qualified opaque Docker archive')
    File.write(File.join(@directory, ServerImage::RECEIPT), JSON.generate(@receipt))
    sums = [ServerImage::ASSET, ServerImage::RECEIPT].sort.map { |name| "#{Digest::SHA256.file(File.join(@directory, name)).hexdigest}  #{name}\n" }.join
    File.write(File.join(@directory, 'SHA256SUMS'), sums)
  end

  it 'publishes only the exact owning tag and qualified product assets after proving absence' do
    expect(@release.publish).to eq("server-v8.0.1-#{@revision}")
    expect(@commands.count { |argv| argv.include?('--include') }).to eq(2)
    expect(@commands[-2]).to include('POST', "ref=refs/tags/server-v8.0.1-#{@revision}", "sha=#{@revision}")
    expect(@commands.last).to include('--verify-tag', '--latest=false', '--target', @revision,
      *[ServerImage::ASSET, ServerImage::RECEIPT, 'SHA256SUMS'].map { |name| File.join(@directory, name) })
    expect(@commands.flatten).not_to include('--clobber', '--delete')
  end

  it 'rejects untrusted contexts and dirty source before release transport' do
    [{ 'GITHUB_EVENT_NAME' => 'pull_request' }, { 'GITHUB_REF' => 'refs/heads/topic' }, { 'GITHUB_REPOSITORY' => 'other/server' }].each do |change|
      expect { described_class.new(@root, @directory, @environment.merge(change)).publish }.to raise_error(ArgumentError, /trusted main/)
    end
    @dirty = true
    expect { @release.publish }.to raise_error(ArgumentError, /dirty/)
    expect(@commands.flatten).not_to include('gh')
  end

  it 'rejects altered bytes, receipt identity and a different owning revision before publication' do
    File.open(File.join(@directory, ServerImage::ASSET), 'ab') { |file| file.write('changed') }
    expect { @release.publish }.to raise_error(ArgumentError, /checksum/)
    @receipt['source']['revision'] = 'c' * 40
    package
    expect { @release.publish }.to raise_error(ArgumentError, /revision/)
    @receipt['source']['revision'] = @revision
    @receipt['extra'] = true
    package
    expect { @release.publish }.to raise_error(ArgumentError, /identity/)
    expect(@commands.flatten).not_to include('gh')
  end

  it 'never overwrites existing releases/tags or guesses transport failure means absence' do
    @exists = true
    expect { @release.publish }.to raise_error(ArgumentError, /absence is unproven/)
    @exists, @api_failure = false, true
    expect { @release.publish }.to raise_error(ArgumentError, /absence is unproven/)
    @exists, @api_failure, @tag_failure = false, false, true
    expect { @release.publish }.to raise_error(IOError, /command failed/)
    expect(@commands.none? { |argv| argv.include?('create') }).to be(true)
  end
end
