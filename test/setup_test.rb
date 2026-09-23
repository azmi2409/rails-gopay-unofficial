# frozen_string_literal: true

require_relative "test_helper"

class SetupTest < Minitest::Test
  def test_accepts_top_level_token_response
    setup_class = Class.new(Rails::Gopay::Unofficial::Setup) do
      private

      def request(method, url, headers:, body: nil)
        return { access_token: "access", refresh_token: "refresh", expires_in: 3600 } if url == Rails::Gopay::Unofficial::Setup::TOKEN_URL

        { merchant: { id: "merchant", name: "Outlet" } }
      end
    end

    result = setup_class.new.verify_otp(phone_number: "08123456789", otp_token: "otp-token", device_id: "device", otp: "123456")

    assert_equal "access", result[:access_token]
    assert_equal "refresh", result[:refresh_token]
    assert_equal "merchant", result[:merchant_id]
  end

  def test_verify_otp_surfaces_provider_error
    setup_class = Class.new(Rails::Gopay::Unofficial::Setup) do
      private

      def request(*, **)
        { success: false, errors: [{ code: "INVALID_OTP", message: "OTP is invalid" }] }
      end
    end

    error = assert_raises(Rails::Gopay::Unofficial::Error) do
      setup_class.new.verify_otp(phone_number: "08123456789", otp_token: "otp-token", device_id: "device", otp: "123456")
    end

    assert_equal "OTP is invalid", error.message
  end

  def test_request_otp_accepts_top_level_token
    setup_class = Class.new(Rails::Gopay::Unofficial::Setup) do
      private

      def request(*, **)
        { otp_token: "top-level-otp", expires_in: 720 }
      end
    end

    result = setup_class.new.request_otp("08123456789")

    assert_equal "top-level-otp", result[:otp_token]
  end
end
