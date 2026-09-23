# rails-gopay-unofficial

Unofficial GoBiz client. Generates dynamic QRIS from a static QRIS payload, refreshes a GoBiz merchant session, fetches settled QRIS transactions, and matches exact IDR payments.

GoPay and GoBiz can change undocumented endpoints or request requirements without notice. Use only with merchant authorization. Do not store QRIS payloads or tokens in logs.

## Install

```ruby
gem "rails-gopay-unofficial", path: "../rails-gopay-unofficial"
```

## QRIS

```ruby
require "rails/gopay/unofficial"

Rails::Gopay::Unofficial.configure do |config|
  config.phone_number = Rails.application.credentials.dig(:gopay, :phone_number)
  config.static_qris = Rails.application.credentials.dig(:gopay, :static_qris)
end

qris = Rails::Gopay::Unofficial::Client.new(
  access_token: session.access_token,
  refresh_token: session.refresh_token,
  merchant_id: session.merchant_id,
  device_id: session.device_id
).create_qris(amount: 50_321)
```

Place configuration in `config/initializers/rails_gopay_unofficial.rb`. Method arguments can override configured values.

## Merchant session and reconciliation

```ruby
client = Rails::Gopay::Unofficial::Client.new(
  access_token: session.access_token,
  refresh_token: session.refresh_token,
  merchant_id: session.merchant_id,
  device_id: session.device_id,
  expires_at: session.expires_at
)

client.refresh! # Persist client.access_token, client.refresh_token, client.expires_at.
transactions = client.transactions_between(start_time: payment.created_at - 60, end_time: Time.now)
match = transactions.lazy.filter_map { |transaction|
  client.match_transaction(transaction, amount: payment.amount, created_at: payment.created_at, expires_at: payment.expires_at)
}.first
```

Persist `device_id` returned by OTP verification and reuse it for every token refresh. GoBiz binds refresh tokens to original device identity. Sessions without original `device_id` must reconnect through OTP.

## First connection

```ruby
setup = Rails::Gopay::Unofficial::Setup.new
pending = setup.request_otp
session_attributes = setup.verify_otp(**pending.slice(:phone_number, :otp_token, :device_id), otp: params[:otp])
# Encrypt and persist session_attributes in application storage.
```

`match_transaction` accepts only `SETTLEMENT` or `CAPTURE` QRIS transactions whose cent-denominated provider amount exactly matches requested IDR amount.

## Test

```sh
ruby -Ilib:test test/qris_test.rb test/client_test.rb
```
