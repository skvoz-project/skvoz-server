# frozen_string_literal: true
require_relative 'spec_helper'
require_relative 'support/system'

RSpec.describe 'Native entry ACME account recovery' do
  EMAIL = 'entry@example.invalid'
  ISSUER = 'https://issuer.invalid/dir'

  around do |example|
    Dir.mktmpdir('skvoz-renew-recovery-') do |temporary|
      @directory = Pathname.new(temporary)
      binary = @directory.join('bin'); binary.mkdir
      FileUtils.cp(Pathname.new(__dir__).join('fixtures/lego.rb'), binary.join('lego'))
      binary.join('lego').chmod(0o700)
      { 'openssl' => 1, 'systemctl' => 0 }.each do |name, status|
        binary.join(name).write("#!/bin/sh\nexit #{status}\n")
        binary.join(name).chmod(0o700)
      end
      shim = @directory.join('seams.sh')
      shim.write('function /usr/local/lib/skvoz-nats/tls.sh { printf "applied\\n" >> "$SKVOZ_NATS_STATE/applied"; }' + "\n")
      @env = { 'PATH' => "#{binary}:#{ENV.fetch('PATH')}", 'BASH_ENV' => shim.to_s,
        'SKVOZ_ACME_EMAIL' => EMAIL, 'SKVOZ_ACME_TERMS_AGREED' => 'true', 'SKVOZ_ACME_DIRECTORY' => ISSUER }
      example.run
    end
  end

  def state(name, registration: nil, issuer: ISSUER)
    root = @directory.join(name); root.mkdir(0o700)
    root.join('address').write("entry.invalid\n")
    cert = root.join('tls/current/certificate.pem')
    cert.dirname.mkpath; cert.write('existing-certificate')
    account = root.join('acme/accounts/issuer.invalid', EMAIL, 'account.json')
    account.dirname.mkpath
    if registration || issuer != ISSUER
      record = { id: EMAIL, email: EMAIL, keyType: 'ec256', server: issuer, registration: registration }
      account.write(JSON.pretty_generate(record, indent: "\t"))
      account.dirname.join("#{EMAIL}.key").write('existing-private-key')
    end
    [root, account, account.dirname.join("#{EMAIL}.key"), cert]
  end

  def invoke(root, mode)
    _, stderr, status = ServerSystem.capture('bash', File.expand_path('../deploy/nats/renew.sh', __dir__),
      env: @env.merge('SKVOZ_NATS_STATE' => root.to_s, 'UPSTREAM_RESULT' => mode), timeout: 5)
    [status.exitstatus, stderr]
  end

  it 'preserves an unregistered orphan and the old certificate, then uses one next scheduled attempt' do
    root, account, key, cert = state('fresh')
    expect(invoke(root, 'transport').first).to eq(17)
    expect(JSON.parse(account.read)['registration']).to be_nil
    original = [account.read, key.read, cert.read]
    status, stderr = invoke(root, 'unknown')
    expect(status).to eq(18)
    expect(stderr).to include('accountDoesNotExist')
    backups = root.glob('acme/unregistered-*')
    expect(backups.size).to eq(1)
    expect(backups.first.stat.mode & 0o777).to eq(0o700)
    expect(backups.first.join('account.json').read).to eq(original[0])
    expect(backups.first.join('account.key').read).to eq(original[1])
    expect(account.exist? || key.exist?).to be(false)
    expect(cert.read).to eq(original[2])
    expect(invoke(root, 'success').first).to eq(0)
    expect(root.join('applied').read).to eq("applied\n")
    expect(JSON.parse(account.read).dig('registration', 'status')).to eq('valid')
    expect(root.join('attempts').read.lines.size).to eq(3)
  end

  it 'never resets registered, wrong-issuer or ambiguous metadata' do
    [ ['registered', { 'status' => 'valid' }, ISSUER],
      ['wrong-issuer', nil, 'https://issuer.invalid/other-dir'],
      ['ambiguous', { 'status' => 'valid' }, ISSUER] ].each do |name, registration, issuer|
      root, account, key, cert = state(name, registration:, issuer:)
      account.write(account.read.sub('"registration": {', "\"unexpected\": {\n\t\"registration\": null,\n\t\"registered\": {")) if name == 'ambiguous'
      before = [account, key, cert].map(&:read)
      expect(invoke(root, 'unknown').first).to eq(18)
      expect([account, key, cert].map(&:read)).to eq(before)
      expect(root.glob('acme/unregistered-*')).to be_empty
    end
  end
end
