# frozen_string_literal: true

module Rails
  module Gopay
    module Unofficial
      class Setup
        OTP_URL = "https://api.gobiz.co.id/goid/login/request"
        TOKEN_URL = Client::TOKEN_URL
        PROFILE_URL = "https://api.gobiz.co.id/goresto/v5/public/users/config"

        def request_otp(phone_number = Unofficial.configuration.phone_number)
          phone_number = normalized_phone(phone_number)
          raise Error, "Enter the Indonesian phone number registered with GoBiz" unless phone_number.match?(/\A8\d{7,13}\z/)

          device_id = SecureRandom.uuid
          data = request(:post, OTP_URL, headers: headers(device_id), body: { client_id: "go-biz-web-new", phone_number:, country_code: "62" })[:data] || {}
          token = data[:otp_token] || data[:login_token]
          raise Error, "GoBiz returned no OTP token" if token.to_s.empty?

          { phone_number:, otp_token: token, device_id:, expires_at: Time.now + Integer(data.fetch(:expires_in, 720)) }
        end

        def verify_otp(phone_number:, otp_token:, device_id:, otp:)
          raise Error, "OTP must contain 4 to 8 digits" unless otp.to_s.match?(/\A\d{4,8}\z/)

          tokens = request(:post, TOKEN_URL, headers: headers(device_id), body: { client_id: "go-biz-web-new", grant_type: "otp", data: { otp: otp.to_s, otp_token: } })[:data] || {}
          raise Error, "GoBiz returned no access token" if tokens[:access_token].to_s.empty?
          raise Error, "GoBiz returned no refresh token; reconnect and try again" if tokens[:refresh_token].to_s.empty?

          merchant = merchant_profile(tokens[:access_token], device_id)
          {
            phone_number: "+62#{normalized_phone(phone_number)}", merchant_id: merchant.fetch(:id), outlet_name: merchant[:name],
            access_token: tokens[:access_token], refresh_token: tokens[:refresh_token], device_id:,
            expires_at: Time.now + Integer(tokens.fetch(:expires_in, 86_400))
          }
        end

        private

        def normalized_phone(phone_number)
          phone_number.to_s.gsub(/\D/, "").sub(/\A62/, "").sub(/\A0/, "")
        end

        def merchant_profile(access_token, device_id)
          data = request(:get, PROFILE_URL, headers: headers(device_id).merge("Authorization" => "Bearer #{access_token}"))[:data] || {}
          merchant = data[:merchant] || data[:merchants]&.first || data[:restaurants]&.first
          raise Error, "No GoBiz merchant found for this account" if merchant&.dig(:id).to_s.empty?

          { id: merchant[:id].to_s, name: merchant[:name] || merchant[:brand_name] }
        end

        def headers(device_id)
          { "Accept" => "application/json, text/plain, */*", "Content-Type" => "application/json", "accept-language" => "id", "authentication-type" => "go-id", "gojek-country-code" => "ID", "gojek-timezone" => "Asia/Jakarta", "Origin" => "https://portal.gofoodmerchant.co.id", "Referer" => "https://portal.gofoodmerchant.co.id/", "User-Agent" => Client::USER_AGENT, "x-appid" => "go-biz-web-dashboard", "x-appversion" => Client::APP_VERSION, "x-deviceos" => "Web", "x-phonemake" => "Windows 10 64-bit", "x-phonemodel" => "Chrome 150.0.0.0 on Windows 10 64-bit", "x-platform" => "Web", "x-uniqueid" => device_id, "x-user-locale" => "en-GB", "x-user-type" => "merchant" }
        end

        def request(method, url, headers:, body: nil)
          uri = URI(url)
          request = Net::HTTP.const_get(method.capitalize).new(uri)
          headers.each { |key, value| request[key] = value }
          request.body = JSON.generate(body) if body
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 15) { |http| http.request(request) }
          parsed = JSON.parse(response.body, symbolize_names: true)
          return parsed if response.code.to_i < 400

          raise Error.new("GoBiz request failed (HTTP #{response.code})", response.code.to_i)
        rescue JSON::ParserError
          raise Error, "GoBiz returned an invalid response"
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => error
          raise Error, "GoBiz network error: #{error.message}"
        end
      end
    end
  end
end
