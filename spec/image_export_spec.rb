# frozen_string_literal: true
require_relative 'spec_helper'
require 'open3'
require 'zlib'
require_relative '../bin/support/server_image'

RSpec.describe 'Ready Server product image export' do
  around do |example|
    Dir.mktmpdir('skvoz-mapped-export-') do |directory|
      @mapped_output = directory
      previous = %w[SKVOZ_BUILDKIT_CONTAINER SKVOZ_BUILD_OUTPUT].to_h { |name| [name, ENV[name]] }
      ENV['SKVOZ_BUILDKIT_CONTAINER'] = 'owned-builder'
      ENV['SKVOZ_BUILD_OUTPUT'] = directory
      example.run
    ensure
      previous.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    end
  end

  def export(*arguments)
    previous = ARGV.dup
    ARGV.replace(arguments)
    load File.expand_path('../bin/export-image', __dir__)
  ensure
    ARGV.replace(previous)
  end

  before do
    @image_id = 'sha256:' + 'b' * 64
    @builder_id = 'c' * 64
    @builder = { 'Id' => @builder_id, 'State' => { 'Running' => true },
      'Config' => { 'Image' => 'moby/buildkit@sha256:a82d1ab899cda51aade6fe818d71e4b58c4079e047a0cf29dbb93b2b0465ea69' },
      'Mounts' => [{ 'Type' => 'bind', 'Source' => @mapped_output, 'Destination' => '/output', 'RW' => true }] }
    @revision, @dirty = nil, false
    @image = { 'Id' => @image_id, 'Os' => 'linux', 'Architecture' => 'amd64',
      'Config' => { 'Entrypoint' => ['skvoz-server'], 'Labels' => { 'org.opencontainers.image.source' => ServerImage::SOURCE,
        'org.opencontainers.image.version' => '8.0.1', 'org.opencontainers.image.revision' => '' } } }
    @commands = []
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3) do |*argv|
      @commands << argv
      command = argv.drop(3)
      if command[0, 3] == %w[docker container inspect]
        [JSON.generate([@builder]), '', status]
      elsif command[0, 3] == %w[docker image inspect]
        [JSON.generate([@image]), '', status]
      elsif command[0, 3] == %w[docker image save]
        File.binwrite(command.fetch(4), 'opaque bytes emitted by Docker image save')
        ['', '', status]
      elsif command[0, 3] == ['docker', 'exec', @builder_id]
        tar, archive = command.last(2).map { |path| @mapped_output + path.delete_prefix('/output') }
        Zlib::GzipWriter.open(archive) do |gzip|
          gzip.mtime = 0
          gzip.write(File.binread(tar))
        end
        ['', '', status]
      elsif command.first == 'git'
        [command.include?('rev-parse') ? @revision.to_s + "\n" : (@dirty ? ' M README.md' : ''), '', status]
      else
        raise "Unexpected export command: #{command}"
      end
    end
  end

  it 'saves only the exact image ID and wraps those bytes with checked receipt and deterministic gzip metadata' do
    Dir.mktmpdir('skvoz-image-export-') do |directory|
      first, second = %w[first second].map { |name| File.join(directory, name) }
      export(@image_id, first)
      export(@image_id, second)
      receipt = ServerImage.read(first)
      expect(receipt).to include('image_id' => @image_id, 'source' => { 'repository' => ServerImage::SOURCE, 'revision' => nil }, 'tag' => nil)
      Zlib::GzipReader.open(File.join(first, ServerImage::ASSET)) do |gzip|
        expect(gzip.mtime.to_i).to eq(0)
        expect(gzip.read).to eq('opaque bytes emitted by Docker image save')
      end
      expect(File.binread(File.join(first, 'SHA256SUMS'))).to eq(File.binread(File.join(second, 'SHA256SUMS')))
      expect(@commands.select { |argv| argv.drop(3).take(3) == %w[docker image save] }.map(&:last)).to eq([@image_id, @image_id])
      original = File.binread(File.join(first, 'SHA256SUMS'))
      expect { export(@image_id, first) }.to raise_error(SystemExit)
      expect(File.binread(File.join(first, 'SHA256SUMS'))).to eq(original)
    end
  end

  it 'rejects wrong source, version, platform, or label and refuses mutable tags before saving bytes' do
    Dir.mktmpdir('skvoz-image-rejection-') do |directory|
      @image['Config']['Labels']['org.opencontainers.image.version'] = 'wrong'
      expect { export(@image_id, File.join(directory, 'wrong-version')) }.to raise_error(SystemExit)
      @image['Config']['Labels']['org.opencontainers.image.version'] = '8.0.1'
      @image['Architecture'] = 'arm64'
      expect { export(@image_id, File.join(directory, 'wrong-target')) }.to raise_error(SystemExit)
      expect { export('skvoz-server:latest', File.join(directory, 'mutable')) }.to raise_error(SystemExit)
      expect(@commands.none? { |argv| argv.drop(3).take(3) == %w[docker image save] }).to be(true)
    end
  end

  it 'embeds only an actual clean owning source commit and rejects mismatches or dirt before Docker' do
    Dir.mktmpdir('skvoz-image-revision-') do |directory|
      @revision = 'a' * 40
      @image['Config']['Labels']['org.opencontainers.image.revision'] = @revision
      export('--revision', @revision, @image_id, File.join(directory, 'valid'))
      expect(ServerImage.read(File.join(directory, 'valid'), revision: @revision).fetch('tag')).to eq("server-v8.0.1-#{@revision}")
      @commands.clear
      expect { export('--revision', 'c' * 40, @image_id, File.join(directory, 'mismatch')) }.to raise_error(SystemExit)
      @dirty = true
      expect { export('--revision', @revision, @image_id, File.join(directory, 'dirty')) }.to raise_error(SystemExit)
      expect(@commands.flatten).not_to include('docker')
    end
  end

  it 'rejects missing prepared output mappings instead of compressing outside the capped daemon' do
    Dir.mktmpdir('skvoz-export-mapping-') do |directory|
      @builder['Mounts'] = []
      expect { export(@image_id, File.join(directory, 'rejected')) }.to raise_error(SystemExit)
      expect(@commands.none? { |argv| argv.drop(3).take(3) == %w[docker image save] }).to be(true)
      expect(File.exist?(File.join(directory, 'rejected'))).to be(false)
    end
  end
end
