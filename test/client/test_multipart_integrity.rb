# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "base64"
require "openssl"
require "stringio"
require "uri"
require "rexml/document"
require "azure_blob"

# Unit tests: the HTTP transport is replaced only inside each stub block.
# No Azure credentials, network connection, emulator, or database is needed.
class TestMultipartIntegrity < Minitest::Test
  PAYLOAD = "\x00ABC\xFFDEF\x80Z".b.freeze
  BLOCK_SIZE = 4

  def test_multipart_string_sends_the_exact_md5_of_every_block
    requests = record_upload(PAYLOAD, block_size: BLOCK_SIZE, content_md5: md5(PAYLOAD))

    assert_equal expected_blocks.map { |body| md5(body) }, block_checksums(requests),
      "Each Put Block must have Content-MD5 for its own bytes, including the final short block"
  end

  def test_multipart_io_sends_the_exact_md5_of_every_block
    requests = record_upload(StringIO.new(PAYLOAD), block_size: BLOCK_SIZE, content_md5: md5(PAYLOAD))

    assert_equal expected_blocks.map { |body| md5(body) }, block_checksums(requests),
      "The IO upload path must also calculate the checksum of each block"
  end

  def test_multipart_hashes_each_block_without_a_whole_blob_checksum
    requests = record_upload(PAYLOAD, block_size: BLOCK_SIZE)

    assert_equal expected_blocks.map { |body| md5(body) }, block_checksums(requests),
      "Per-block integrity must not depend on receiving a whole-blob checksum"
  end

  def test_multipart_preserves_binary_bytes_block_order_and_whole_blob_checksum
    requests = record_upload(PAYLOAD, block_size: BLOCK_SIZE, content_md5: md5(PAYLOAD))
    blocks = requests.select { |request| request[:operation] == "block" }
    commits = requests.select { |request| request[:operation] == "blocklist" }

    assert_equal expected_blocks, blocks.map { |request| request[:body] }
    assert_equal [ 4, 4, 2 ], blocks.map { |request| request[:body].bytesize }
    assert_equal PAYLOAD, blocks.map { |request| request[:body] }.join
    assert_equal 1, commits.length
    assert_equal "blocklist", requests.last[:operation]
    assert_equal md5(PAYLOAD), commits.first[:headers]["x-ms-blob-content-md5"]

    committed_ids = REXML::Document.new(commits.first[:body]).root.elements.map(&:text)
    assert_equal blocks.map { |request| request[:query].fetch("blockid") }, committed_ids
  end

  def test_multipart_preserves_timeout_on_blocks_and_commit
    requests = record_upload(PAYLOAD, block_size: BLOCK_SIZE, timeout: 7)

    assert_equal [ "block", "block", "block", "blocklist" ], requests.map { |request| request[:operation] }
    assert_equal [ "7", "7", "7", "7" ], requests.map { |request| request[:query]["timeout"] }
  end

  def test_single_request_upload_preserves_payload_and_whole_blob_checksum
    requests = record_upload(PAYLOAD, block_size: PAYLOAD.bytesize, content_md5: md5(PAYLOAD))

    assert_equal 1, requests.length
    assert_equal "blob", requests.first[:operation]
    assert_equal PAYLOAD, requests.first[:body]
    assert_equal md5(PAYLOAD), requests.first[:headers]["x-ms-blob-content-md5"]
  end

  private

  def md5(bytes)
    OpenSSL::Digest::MD5.base64digest(bytes)
  end

  def expected_blocks
    [ PAYLOAD.byteslice(0, 4), PAYLOAD.byteslice(4, 4), PAYLOAD.byteslice(8, 2) ]
  end

  def block_checksums(requests)
    requests.select { |request| request[:operation] == "block" }.
      map { |request| request[:headers]["content-md5"] }
  end

  def record_upload(content, **options)
    requests = []
    factory = lambda do |uri, headers = {}, **_http_options|
      query = URI.decode_www_form(uri.query.to_s).to_h
      request = {
        operation: query.fetch("comp", "blob"),
        query: query,
        headers: headers.transform_keys { |name| name.to_s.downcase },
      }
      transport = Object.new
      transport.define_singleton_method(:put) do |body = nil|
        bytes = body.respond_to?(:read) ? body.read : body
        requests << request.merge(body: bytes&.dup)
        nil
      end
      transport
    end

    # Synthetic Shared Key: it is never sent to any service.
    client = AzureBlob::Client.new(
      account_name: "unitaccount",
      access_key: Base64.strict_encode64("unit-test-key-not-a-credential"),
      container: "unit-container",
      host: "https://storage.invalid",
    )

    AzureBlob::Http.stub(:new, factory) do
      client.create_block_blob("unit/payload.bin", content, options)
    end
    requests
  end
end
