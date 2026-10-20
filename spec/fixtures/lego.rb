#!/usr/bin/env ruby
# frozen_string_literal: true
require 'json'
require 'fileutils'
root = ENV.fetch('SKVOZ_NATS_STATE')
email = 'entry@example.invalid'
folder = File.join(root, 'acme/accounts/issuer.invalid', email)
FileUtils.mkdir_p(folder)
account = File.join(folder, 'account.json')
key = File.join(folder, "#{email}.key")
File.open(File.join(root, 'attempts'), 'a') { |file| file.puts('attempt') }
unless File.exist?(account)
  File.write(key, 'unregistered-private-key', perm: 0o600)
  record = { id: email, email: email, keyType: 'ec256', server: 'https://issuer.invalid/dir', registration: nil }
  File.write(account, JSON.pretty_generate(record, indent: "\t"), perm: 0o600)
end
case ENV.fetch('UPSTREAM_RESULT')
when 'transport'
  warn 'temporary issuer transport failure'
  exit 17
when 'unknown'
  warn 'resolve account by key: urn:ietf:params:acme:error:accountDoesNotExist'
  exit 18
end
record = JSON.parse(File.read(account))
record['registration'] = { 'status' => 'valid' }
File.write(account, JSON.pretty_generate(record, indent: "\t"))
certificates = File.join(root, 'acme/certificates')
FileUtils.mkdir_p(certificates)
File.write(File.join(certificates, 'entry.invalid.crt'), 'new-certificate')
File.write(File.join(certificates, 'entry.invalid.key'), 'new-certificate-key')
