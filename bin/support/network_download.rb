# frozen_string_literal: true
require 'digest'
require 'json'
require 'net/http'
require 'timeout'
require 'uri'

# Download exact release bytes before standard archive extraction.
module NetworkDownload
  LIMIT = 256 * 1024 * 1024

  def self.lock(path)
    bytes = File.binread(path, 65_537)
    raise ArgumentError, 'Network lock exceeds limit' if bytes.bytesize > 65_536
    value = JSON.parse(bytes, allow_duplicate_key: false)
    artifact = value.fetch('artifact')
    unless artifact.is_a?(Hash) && artifact.keys.sort == %w[sha256 url] &&
        artifact['sha256'].is_a?(String) && artifact['sha256'].match?(/\A[0-9a-f]{64}\z/) &&
        artifact['url'].is_a?(String) && artifact['url'].bytesize.between?(1, 4096)
      raise ArgumentError, 'Invalid Network artifact locator'
    end
    value
  end

  def self.fetch(url, destination, sha256: nil, limit: LIMIT, base: Dir.pwd)
    created = false
    Timeout.timeout(120) do
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
        created = true
        size = 0
        append = lambda do |bytes|
          size += bytes.bytesize
          raise IOError, 'Network download exceeds limit' if size > limit
          output.write(bytes)
        end
        uri = URI(url)
        if uri.scheme == 'file'
          raise ArgumentError, 'Invalid local Network URL' unless uri.host.nil? || uri.host.empty?
          File.open(File.expand_path(URI::DEFAULT_PARSER.unescape(uri.path || uri.opaque), base), 'rb') do |input|
            while (bytes = input.read(65_536)); append.call(bytes); end
          end
        else
          https(uri, 3, &append)
        end
        output.flush
        output.fsync
      end
      raise IOError, 'Network archive checksum mismatch' if sha256 && Digest::SHA256.file(destination).hexdigest != sha256
    end
    destination
  rescue StandardError
    File.unlink(destination) if created && File.file?(destination)
    raise
  end

  def self.https(uri, redirects, &append)
    unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment
      raise ArgumentError, 'Network download requires HTTPS'
    end
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
        if response.is_a?(Net::HTTPRedirection)
          raise IOError, 'Network redirect limit exceeded' unless redirects.positive?
          https(URI.join(uri, response.fetch('location')), redirects - 1, &append)
        elsif response.is_a?(Net::HTTPSuccess)
          response.read_body(&append)
        else
          raise IOError, "Network download failed: HTTP #{response.code}"
        end
      end
    end
  end
end
