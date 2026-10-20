# frozen_string_literal: true
require 'digest'
require 'json'

module ServerImage
  REPOSITORY = 'skvoz-project/skvoz-server'
  ASSET = 'skvoz-server-8.0.1-x86_64-unknown-linux-gnu.docker.tar.gz'
  RECEIPT = 'server-image.json'
  SOURCE = "https://github.com/#{REPOSITORY}"

  # Packaging also runs on the CI host's Ruby, outside the application gem set.
  class UniqueObject < Hash
    def []=(key, value)
      raise ArgumentError, 'Duplicate Server image metadata key' if key?(key)
      super
    end
  end

  def self.read(directory, revision: nil)
    receipt_path = File.join(directory, RECEIPT)
    raise ArgumentError, 'Invalid Server image receipt file' unless File.lstat(receipt_path).file? && File.size(receipt_path) <= 65_536
    value = JSON.parse(File.binread(receipt_path), object_class: UniqueObject, max_nesting: 8)
    source = value['source']
    unless value.keys.sort == %w[component image_id schema source tag target version] &&
        value.values_at('schema', 'component', 'version', 'target') == [1, 'skvoz-server', '8.0.1', 'x86_64-unknown-linux-gnu'] &&
        source.is_a?(Hash) && source.keys.sort == %w[repository revision] && source['repository'] == SOURCE &&
        value['image_id'].is_a?(String) && value['image_id'].match?(/\Asha256:[0-9a-f]{64}\z/)
      raise ArgumentError, 'Invalid Server image identity'
    end
    owning = source['revision']
    valid_source = owning.nil? ? value['tag'].nil? : owning.is_a?(String) && owning.match?(/\A[0-9a-f]{40}\z/) && value['tag'] == "server-v8.0.1-#{owning}"
    raise ArgumentError, 'Invalid Server owning source revision/tag' unless valid_source && (!revision || owning == revision)
    names = [ASSET, RECEIPT].sort
    expected = names.map do |name|
      path = File.join(directory, name)
      raise ArgumentError, 'Invalid Server release asset file' unless File.lstat(path).file? && File.size(path).between?(1, 512 * 1024 * 1024)
      "#{Digest::SHA256.file(path).hexdigest}  #{name}\n"
    end.join
    raise ArgumentError, 'Server release checksum mismatch' unless File.binread(File.join(directory, 'SHA256SUMS'), 65_537) == expected
    value
  end
end
