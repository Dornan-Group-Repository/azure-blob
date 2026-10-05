# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "logger"
require "openssl"
require "stringio"
require "active_support/all"
require "active_storage"
require "active_storage/service"
require "active_storage/service/azure_blob_service"

# Service configuration unit tests, without booting the Rails dummy app.
# Replacing Client.new avoids authentication, HTTP and database access.
class AzureBlobUploadOptionsTest < Minitest::Test
  PAYLOAD = "test payload".b.freeze
  CONTENT_TYPE = "application/octet-stream"
  CUSTOM_METADATA = { "purpose" => "upload-options-unit-test" }.freeze

  def test_configured_block_size_reaches_the_client_upload
    upload = capture_upload(block_size: 4)

    assert_equal 4, upload[:options][:block_size],
      "The ActiveStorage service must forward its configured block_size to create_block_blob"
  end

  def test_omitting_block_size_keeps_the_existing_client_default
    upload = capture_upload
    effective_size = upload[:options][:block_size] || AzureBlob::DEFAULT_BLOCK_SIZE

    assert_equal AzureBlob::DEFAULT_BLOCK_SIZE, effective_size
  end

  def test_upload_preserves_the_existing_payload_checksum_and_metadata
    upload = capture_upload

    assert_equal "unit/payload.bin", upload[:key]
    assert_equal PAYLOAD, upload[:body]
    assert_equal OpenSSL::Digest::MD5.base64digest(PAYLOAD), upload[:options][:content_md5]
    assert_equal CONTENT_TYPE, upload[:options][:content_type]
    assert_equal CUSTOM_METADATA, upload[:options][:metadata]
  end

  private

  def capture_upload(**service_options)
    uploads = []
    client = Object.new
    client.define_singleton_method(:create_block_blob) do |key, io, **options|
      uploads << { key: key, body: io.read, options: options }
      nil
    end

    configuration = {
      service: "AzureBlob",
      storage_account_name: "unitaccount",
      storage_access_key: "unused-by-stub",
      container: "unit-container",
      storage_blob_host: "https://storage.invalid",
    }.merge(service_options)

    service = AzureBlob::Client.stub(:new, client) do
      ActiveStorage::Service.configure(:dfma_upload_options, { dfma_upload_options: configuration })
    end

    service.upload(
      "unit/payload.bin",
      StringIO.new(PAYLOAD),
      checksum: OpenSSL::Digest::MD5.base64digest(PAYLOAD),
      content_type: CONTENT_TYPE,
      custom_metadata: CUSTOM_METADATA,
    )

    assert_equal 1, uploads.length, "Expected exactly one call to create_block_blob"
    uploads.first
  end
end
