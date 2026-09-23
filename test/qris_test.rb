# frozen_string_literal: true

require_relative "test_helper"

class QrisTest < Minitest::Test
  def setup
    merchant = "ID.CO.TEST.WWW"
    @base = "00020101021126#{merchant.bytesize.to_s.rjust(2, "0")}#{merchant}53033605802ID5913TEST MERCHANT6007JAKARTA6304"
    @template = @base + Rails::Gopay::Unofficial::Qris.crc16(@base)
    Rails::Gopay::Unofficial.configuration.static_qris = @template
  end

  def test_generates_dynamic_qris_with_exact_amount
    result = Rails::Gopay::Unofficial::Qris.generate(@template, 50_321)
    tags = Rails::Gopay::Unofficial::Qris.parse(result)

    assert_equal "12", tags.assoc("01").last
    assert_equal "50321", tags.assoc("54").last
    assert_equal Rails::Gopay::Unofficial::Qris.crc16(result[0...-4]), result[-4, 4]
  end

  def test_rejects_invalid_checksum
    assert_raises(Rails::Gopay::Unofficial::Error) { Rails::Gopay::Unofficial::Qris.generate(@template.sub(/.\z/, "0"), 50_321) }
  end

  def test_client_uses_configured_static_qris
    client = Rails::Gopay::Unofficial::Client.new(access_token: "access", refresh_token: "refresh", merchant_id: "merchant", phone_number: "+628123456789")

    result = client.create_qris(amount: 50_321)

    assert_equal "50321", Rails::Gopay::Unofficial::Qris.parse(result[:qris_code]).assoc("54").last
  end
end
