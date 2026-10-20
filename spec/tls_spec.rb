# frozen_string_literal: true
require_relative 'spec_helper'
require_relative 'support/system'

RSpec.describe 'Verified broker TLS identity', integration: true do
  include ServerSystem

  before(:context) do
    @directory = Pathname.new(Dir.mktmpdir('skvoz-tls-spec-'))
    @directory.chmod(0o700)
    @ca, @ca_key, @key = certificates(@directory, identity: 'server.invalid', san: 'IP:203.0.113.9,DNS:server.invalid')
    wrong_key = OpenSSL::PKey::RSA.new(2048)
    @directory.join('wrong.pem').write(certificate(key: wrong_key, name: 'Unrelated CA', ca: true).to_pem)
    @directory.join('wrong.pem').chmod(0o600)
    @directory.join('empty.pem').write("not a PEM root certificate\n")
    @directory.join('empty.pem').chmod(0o600)
    @password = SecureRandom.urlsafe_base64(32)
  end

  after do
    terminate(@broker, timeout: 5) if @broker
    @output&.close
    @broker = nil
  end

  after(:context) { FileUtils.remove_entry(@directory) }

  def broker(leaf = @directory.join('server.pem'))
    @port = free_port
    config = @directory.join('nats.conf')
    config.write(<<~CONF)
      listen: "127.0.0.1:#{@port}"
      max_payload: 65588
      tls { cert_file: #{JSON.generate(leaf.to_s)}, key_file: #{JSON.generate(@directory.join('server.key').to_s)}, handshake_first: false }
      authorization { users: [{user: "tls-check", password: #{JSON.generate(@password)}}] }
    CONF
    config.chmod(0o600)
    @output = File.open(@directory.join('nats.log'), 'wb')
    @broker = Process.spawn(ServerSystem::NATS, '-c', config.to_s, out: @output, err: @output)
    wait_until do
      raise IOError, 'Test broker exited before readiness' if process_dead(@broker)
      @directory.join('nats.log').read.include?('Server is ready')
    end
  end

  def broker_case(updates = {}, succeeds: false)
    identity = updates.fetch('tls_server_name', '203.0.113.9') || '127.0.0.1'
    ca = updates['trust'] == 'system' ? nil : updates.fetch('ca_file', @directory.join('ca.pem').to_s)
    connect = lambda do
      Timeout.timeout(5) do
        socket = Skvoz::Server::BrokerTLS.connect(TCPSocket.new('127.0.0.1', @port), identity:, ca:)
        socket.close
      end
    end
    succeeds ? connect.call : expect(&connect).to(raise_error(OpenSSL::OpenSSLError))
  end

  {
    'verifies a public IP SAN through a loopback dial' => [{}, true],
    'verifies a DNS SAN through a loopback dial' => [{ 'tls_server_name' => 'server.invalid' }, true],
    'checks the dial identity when the override is absent' => [{ 'tls_server_name' => nil }, false],
    'rejects the wrong verification identity' => [{ 'tls_server_name' => 'different.invalid' }, false],
    'rejects an unrelated trust root' => [:wrong_root, false],
    'rejects an empty trust root file' => [:empty_root, false],
    'rejects a malformed bracketed verification identity' => [{ 'tls_server_name' => '[::1]' }, false],
    'rejects a private CA with ordinary System roots' => [{ 'trust' => 'system' }, false]
  }.each do |description, (updates, succeeds)|
    it description do
      broker
      updates = { 'ca_file' => @directory.join(updates == :wrong_root ? 'wrong.pem' : 'empty.pem').to_s } if updates.is_a?(Symbol)
      broker_case(updates, succeeds:)
    end
  end

  it 'rejects an expired leaf over an actual NATS handshake' do
    leaf = @directory.join('expired.pem')
    leaf.write(certificate(key: @key, issuer: @ca, issuer_key: @ca_key, name: 'server.invalid',
      san: 'IP:203.0.113.9,DNS:server.invalid', expires: Time.now - 1).to_pem)
    leaf.chmod(0o600)
    broker(leaf)
    broker_case
  end

  [['wrong server EKU', 'IP:203.0.113.9,DNS:server.invalid', 'clientAuth']].each do |name, san, eku|
    it "rejects #{name} in both Ruby handshake and TLS material" do
      leaf = @directory.join(SecureRandom.hex(8) + '.pem')
      leaf.write(certificate(key: @key, issuer: @ca, issuer_key: @ca_key, name: 'server.invalid', san:, eku:).to_pem)
      leaf.chmod(0o600)
      broker(leaf)
      broker_case({ 'tls_server_name' => 'server.invalid' })
      expect do
        Skvoz::Server::TLSMaterial.new(certificate: leaf.to_s, key: @directory.join('server.key').to_s,
          ca: @directory.join('ca.pem').to_s, identity: 'server.invalid')
      end.to raise_error(Skvoz::Server::Error)
    end
  end
end

RSpec.describe 'Server certificate SAN policy' do
  include ServerSystem
  it 'rejects a CN-only certificate during candidate material validation' do
    Dir.mktmpdir('skvoz-san-') do |directory|
      ca, ca_key, key = certificates(directory)
      leaf = Pathname.new(directory).join('server.pem')
      leaf.write(certificate(key:, issuer: ca, issuer_key: ca_key, name: 'localhost').to_pem)
      expect do
        Skvoz::Server::TLSMaterial.new(certificate: leaf.to_s, key: File.join(directory, 'server.key'),
          ca: File.join(directory, 'ca.pem'), identity: 'localhost')
      end.to raise_error(Skvoz::Server::Error)
    end
  end
end
