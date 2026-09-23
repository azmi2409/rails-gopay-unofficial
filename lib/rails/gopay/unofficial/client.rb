# frozen_string_literal: true

module Rails
  module Gopay
    module Unofficial
      class Client
        TRANSACTIONS_URL = "https://api.gojekapi.com/merchant-analytics/v2/merchants/transactions"
        TOKEN_URL = "https://api.gobiz.co.id/goid/token"
        USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
        APP_VERSION = "platform-v3.111.0-1708bc9a"

        def initialize(access_token:, refresh_token:, merchant_id:, phone_number: Unofficial.configuration.phone_number, device_id: nil, expires_at: nil)
          @access_token = access_token
          @refresh_token = refresh_token
          @merchant_id = merchant_id
          @phone_number = phone_number
          @device_id = device_id
          @expires_at = expires_at
        end

        attr_reader :access_token, :refresh_token, :merchant_id, :phone_number, :device_id, :expires_at

        def create_qris(amount:, reference: nil, static_qris: Unofficial.configuration.static_qris)
          raise Error, "GoPay static QRIS is not configured" if static_qris.to_s.empty?

          amount = Integer(amount)
          { qris_id: SecureRandom.hex(16), qris_code: Qris.generate(static_qris, amount), amount: amount, reference: reference }
        rescue ArgumentError, TypeError
          raise Error, "Invalid payment amount"
        end

        def refresh!
          raise Error, "GoPay refresh token is not configured" if refresh_token.to_s.empty?
          raise Error, "Original GoBiz device ID is missing; reconnect with OTP" if device_id.to_s.strip.empty?
          raise Error, "GoPay phone number is not configured" if normalized_phone.empty?

          payload = request(:post, TOKEN_URL, headers: gobiz_headers, body: {
            client_id: "go-biz-web-new", grant_type: "refresh_token",
            data: { refresh_token: refresh_token, phone_number: normalized_phone, country_code: "62" }
          })
          raise Error, Response.error(payload) if Response.error(payload)

          data = Response.data(payload)
          raise Error, "GoBiz returned no access token" if data[:access_token].to_s.empty?

          @access_token = data[:access_token]
          @refresh_token = data[:refresh_token] unless data[:refresh_token].to_s.empty?
          @expires_at = Time.now + Unofficial.duration(data[:expires_in], 86_400)
          self
        end

        def transactions_between(start_time:, end_time:)
          refresh! if expires_at && expires_at <= Time.now + 900
          offset = 0
          all = []
          loop do
            response = transactions_page(start_time:, end_time:, offset:)
            page = response[:transactions] || (response[:data].is_a?(Array) ? response[:data] : response.dig(:data, :transactions)) || []
            all.concat(page)
            break if page.size < 100 || offset >= 900

            offset += 100
          end
          all
        end

        def match_transaction(transaction, amount:, created_at:, expires_at:)
          return unless %w[SETTLEMENT CAPTURE].include?(transaction[:transaction_status].to_s.upcase)
          return unless transaction[:payment_type].to_s.upcase == "QRIS"

          id = transaction[:id] || transaction[:order_id] || transaction[:wallstreet_transaction_id]
          paid_at = Time.iso8601((transaction[:transaction_time] || transaction[:settlement_time] || transaction[:created_at]).to_s)
          return if id.to_s.empty? || paid_at < created_at - 60 || paid_at > expires_at || !amount_matches?(transaction, amount)

          { transaction_id: id.to_s, payer_issuer: transaction[:qris_provider_aspi_issuer].to_s.empty? ? "GoPay / Bank" : transaction[:qris_provider_aspi_issuer], transaction_time: paid_at, amount: amount }
        rescue ArgumentError
          nil
        end

        private

        def transactions_page(start_time:, end_time:, offset:, retried: false)
          response = request(:get, TRANSACTIONS_URL, headers: authorization_headers, params: {
            from: offset, size: 100, statuses: "SETTLEMENT,CAPTURE", payment_types: "QRIS",
            start_time: start_time.iso8601, end_time: end_time.iso8601, merchant_ids: merchant_id
          }, raise_on_error: false)
          status = response.delete(:_status)
          return response unless status
          raise Error.new(Response.error(response) || "GoPay request failed", status) unless status == 401 && !retried

          refresh!
          transactions_page(start_time:, end_time:, offset:, retried: true)
        end

        def amount_matches?(transaction, target)
          value = transaction[:gross_amount] || transaction[:real_gross_amount] || transaction.dig(:amount, :value) || transaction[:amount]
          raw = Integer(value)
          (raw % 100).zero? && raw / 100 == target
        rescue ArgumentError, TypeError
          false
        end

        def normalized_phone
          phone_number.to_s.gsub(/\D/, "").sub(/\A62/, "").sub(/\A0/, "")
        end

        def authorization_headers
          { "Authorization" => "Bearer #{access_token}", "Cookie" => "access_token=#{access_token}; refresh_token=#{refresh_token}; auth_method=goid", "authentication-type" => "go-id", "Accept" => "application/json, text/plain, */*", "Origin" => "https://portal.gofoodmerchant.co.id", "Referer" => "https://portal.gofoodmerchant.co.id/", "User-Agent" => USER_AGENT }
        end

        def gobiz_headers
          authorization_headers.reject { |key,| ["Authorization", "Cookie"].include?(key) }.merge(
            "Content-Type" => "application/json", "accept-language" => "id", "gojek-country-code" => "ID", "gojek-timezone" => "Asia/Jakarta", "x-appid" => "go-biz-web-dashboard", "x-appversion" => APP_VERSION, "x-deviceos" => "Web", "x-phonemake" => "Windows 10 64-bit", "x-phonemodel" => "Chrome 150.0.0.0 on Windows 10 64-bit", "x-platform" => "Web", "x-uniqueid" => device_id, "x-user-locale" => "en-GB", "x-user-type" => "merchant"
          )
        end

        def request(method, url, headers:, body: nil, params: nil, raise_on_error: true)
          uri = URI(url)
          uri.query = URI.encode_www_form(params) if params
          request = Net::HTTP.const_get(method.capitalize).new(uri)
          headers.each { |key, value| request[key] = value }
          request.body = JSON.generate(body) if body
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 10) { |http| http.request(request) }
          parsed = JSON.parse(response.body, symbolize_names: true)
          return parsed if response.code.to_i < 400
          return parsed.merge(_status: response.code.to_i) unless raise_on_error

          raise Error.new(Response.error(parsed) || "GoPay request failed", response.code.to_i)
        rescue JSON::ParserError
          raise Error, "GoPay returned an invalid response"
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => error
          raise Error, "GoPay network error: #{error.message}"
        end
      end
    end
  end
end
