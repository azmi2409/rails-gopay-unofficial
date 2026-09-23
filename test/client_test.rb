# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def setup
    Rails::Gopay::Unofficial.configure do |config|
      config.phone_number = "+628123456789"
      config.static_qris = nil
    end
  end

  def test_matches_provider_cent_amount_inside_payment_window
    client = Rails::Gopay::Unofficial::Client.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", phone_number: "+628123456789")
    now = Time.now
    transaction = { id: "WTRX-1", gross_amount: 5_032_100, transaction_status: "SETTLEMENT", payment_type: "QRIS", transaction_time: now.iso8601, qris_provider_aspi_issuer: "BANK" }

    result = client.match_transaction(transaction, amount: 50_321, created_at: now - 60, expires_at: now + 300)

    assert_equal "WTRX-1", result[:transaction_id]
    assert_equal 50_321, result[:amount]
  end

  def test_rejects_whole_idr_amount
    client = Rails::Gopay::Unofficial::Client.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", phone_number: "+628123456789")
    now = Time.now
    transaction = { id: "WTRX-1", gross_amount: 50_321, transaction_status: "SETTLEMENT", payment_type: "QRIS", transaction_time: now.iso8601 }

    assert_nil client.match_transaction(transaction, amount: 50_321, created_at: now - 60, expires_at: now + 300)
  end

  def test_uses_configured_phone_number
    client = Rails::Gopay::Unofficial::Client.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant")

    assert_equal "+628123456789", client.phone_number
  end

  def test_refresh_reuses_original_device_fingerprint
    client_class = Class.new(Rails::Gopay::Unofficial::Client) do
      attr_reader :request_options

      private

      def request(*, **options)
        @request_options = options
        { data: { access_token: "new-access", refresh_token: "new-refresh", expires_in: 3600 } }
      end
    end
    client = client_class.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", device_id: "otp-device-id")

    client.refresh!

    assert_equal "otp-device-id", client.request_options[:headers]["x-uniqueid"]
    assert_equal Rails::Gopay::Unofficial::Client::APP_VERSION, client.request_options[:headers]["x-appversion"]
    assert_equal "Windows 10 64-bit", client.request_options[:headers]["x-phonemake"]
    assert_equal "Chrome 150.0.0.0 on Windows 10 64-bit", client.request_options[:headers]["x-phonemodel"]
    assert_equal "8123456789", client.request_options[:body].dig(:data, :phone_number)
  end

  def test_refresh_accepts_top_level_token_response
    client_class = Class.new(Rails::Gopay::Unofficial::Client) do
      private

      def request(*, **)
        { access_token: "top-level-access", refresh_token: "top-level-refresh", expires_in: 3600 }
      end
    end
    client = client_class.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", device_id: "otp-device-id")

    client.refresh!

    assert_equal "top-level-access", client.access_token
    assert_equal "top-level-refresh", client.refresh_token
  end

  def test_refresh_tolerates_string_or_missing_expiry
    client_class = Class.new(Rails::Gopay::Unofficial::Client) do
      private

      def request(*, **)
        { data: { access_token: "new-access", refresh_token: "new-refresh", expires_in: "3600" } }
      end
    end
    client = client_class.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", device_id: "otp-device-id")

    client.refresh!

    assert_in_delta Time.now.to_f + 3600, client.expires_at.to_f, 5

    nil_expiry = Class.new(Rails::Gopay::Unofficial::Client) do
      private

      def request(*, **)
        { data: { access_token: "new-access", refresh_token: "new-refresh" } }
      end
    end.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", device_id: "otp-device-id")

    nil_expiry.refresh!

    assert_operator nil_expiry.expires_at, :>, Time.now + 3600
  end

  def test_refresh_surfaces_provider_error
    client_class = Class.new(Rails::Gopay::Unofficial::Client) do
      private

      def request(*, **)
        { success: false, errors: [{ code: "TOKEN_EXPIRED", message: "Refresh token expired" }] }
      end
    end
    client = client_class.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", device_id: "otp-device-id")

    error = assert_raises(Rails::Gopay::Unofficial::Error) { client.refresh! }

    assert_equal "Refresh token expired", error.message
  end

  def test_refresh_surfaces_oauth_style_error
    client_class = Class.new(Rails::Gopay::Unofficial::Client) do
      private

      def request(*, **)
        { error: "invalid_grant", error_description: "Refresh token is expired" }
      end
    end
    client = client_class.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", device_id: "otp-device-id")

    error = assert_raises(Rails::Gopay::Unofficial::Error) { client.refresh! }

    assert_equal "invalid_grant; Refresh token is expired", error.message
  end

  def test_refresh_rejects_missing_original_device_id
    client = Rails::Gopay::Unofficial::Client.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant")

    error = assert_raises(Rails::Gopay::Unofficial::Error) { client.refresh! }

    assert_equal "Original GoBiz device ID is missing; reconnect with OTP", error.message
  end

  def test_matching_does_not_require_phone_number
    client = Rails::Gopay::Unofficial::Client.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", phone_number: "")
    now = Time.now
    transaction = { id: "WTRX-1", gross_amount: 5_032_100, transaction_status: "SETTLEMENT", payment_type: "QRIS", transaction_time: now.iso8601 }

    assert_equal "WTRX-1", client.match_transaction(transaction, amount: 50_321, created_at: now - 60, expires_at: now + 300)[:transaction_id]
  end
end
