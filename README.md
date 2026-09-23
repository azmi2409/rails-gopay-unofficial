# rails-gopay-unofficial

[![Gem Version](https://badge.fury.io/rb/rails-gopay-unofficial.svg)](https://rubygems.org/gems/rails-gopay-unofficial)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Unofficial Ruby/Rails client for GoPay / GoBiz merchant services. Convert static GoBiz QRIS strings into dynamic QRIS with custom amounts, automate GoBiz merchant session authentication via OTP, query settled QRIS transactions, and match exact IDR payments for automated order fulfillment.

> **Disclaimer**: This is an unofficial library interacting with GoBiz web APIs. GoPay/GoBiz may modify internal endpoints or authentication policies at any time. Use only with explicit merchant authorization and at your own risk. Never log access tokens, refresh tokens, or raw payment payloads.

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
- [Authentication Workflow](#authentication-workflow)
  - [1. Request Login OTP](#1-request-login-otp)
  - [2. Verify OTP and Store Session](#2-verify-otp-and-store-session)
- [Dynamic QRIS Generation](#dynamic-qris-generation)
  - [Generating the Payload](#generating-the-payload)
  - [Rendering QR Codes in Rails](#rendering-qr-codes-in-rails)
- [Transaction Reconciliation](#transaction-reconciliation)
  - [Initializing the Client](#initializing-the-client)
  - [Checking Transactions & Matching](#checking-transactions--matching)
  - [Background Polling Pattern](#background-polling-pattern)
- [Pure QRIS Helper](#pure-qris-helper)
- [Error Handling](#error-handling)
- [Running Tests](#running-tests)
- [License](#license)

---

## Features

- **Dynamic QRIS from Static**: Transforms static EMVCo QRIS (tag `01` = `11`) into dynamic QRIS (tag `01` = `12`) with exact IDR amount (tag `54`) and recalculated CRC-16 checksums.
- **GoBiz Auth & Session Management**: Built-in OTP challenge flow, automated token refreshing, and device ID binding.
- **Transaction Polling**: Fetches settled and captured QRIS transactions across custom time intervals with automatic 401 retry and token renewal.
- **Deterministic Payment Matching**: Safely matches incoming payments against transaction time windows, settled status, and cent-normalized amounts.
- **Zero Heavy Dependencies**: Built entirely on Ruby's standard library (`net/http`, `json`, `securerandom`).

---

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem "rails-gopay-unofficial"
```

Or install via RubyGems:

```sh
gem install rails-gopay-unofficial
```

---

## Configuration

Set up an initializer in `config/initializers/rails_gopay_unofficial.rb`:

```ruby
require "rails/gopay/unofficial"

Rails::Gopay::Unofficial.configure do |config|
  # Registered phone number with GoBiz (e.g. "08123456789" or "+628123456789")
  config.phone_number = Rails.application.credentials.dig(:gopay, :phone_number)

  # Static QRIS payload string obtained from GoBiz merchant portal or printout
  config.static_qris = Rails.application.credentials.dig(:gopay, :static_qris)
end
```

Configuration values can also be overridden per-call on method arguments.

---

## Authentication Workflow

GoBiz requires an OTP verification flow to authenticate. The server issues a pair of `access_token` and `refresh_token` tied to a unique `device_id`.

> **Important**: You MUST persist the `device_id` generated during OTP request and reuse it across all subsequent client initializations and token refreshes. GoBiz binds refresh tokens strictly to the device identifier that requested them.

### 1. Request Login OTP

Trigger an SMS/WhatsApp OTP to the registered merchant phone number:

```ruby
setup = Rails::Gopay::Unofficial::Setup.new

# Returns: { phone_number:, otp_token:, device_id:, expires_at: }
pending_auth = setup.request_otp

# Store pending_auth[:otp_token] and pending_auth[:device_id] in session or DB
session[:gopay_otp_token] = pending_auth[:otp_token]
session[:gopay_device_id] = pending_auth[:device_id]
```

### 2. Verify OTP and Store Session

Verify the received OTP (4 to 8 digits) and retrieve merchant credentials:

```ruby
setup = Rails::Gopay::Unofficial::Setup.new

session_attributes = setup.verify_otp(
  phone_number: Rails::Gopay::Unofficial.configuration.phone_number,
  otp_token: session[:gopay_otp_token],
  device_id: session[:gopay_device_id],
  otp: params[:otp] # e.g. "1234"
)

# Returns:
# {
#   phone_number:  "+6281234567890",
#   merchant_id:   "12345678-abcd-...",
#   outlet_name:   "Kopi Kenangan",
#   access_token:  "eyJhbGciOi...",
#   refresh_token: "eyJhbGciOi...",
#   device_id:     "123e4567-e89b-12d3-a456-426614174000",
#   expires_at:    2026-09-24 10:00:00 +0700
# }

# Encrypt and persist session_attributes in your database
CurrentMerchant.create!(session_attributes)
```

---

## Dynamic QRIS Generation

### Generating the Payload

Use `Client#create_qris` or pass an amount directly:

```ruby
client = Rails::Gopay::Unofficial::Client.new(
  access_token: session.access_token,
  refresh_token: session.refresh_token,
  merchant_id: session.merchant_id,
  device_id: session.device_id
)

qris_data = client.create_qris(
  amount: 50_000,          # Integer in IDR
  reference: "ORDER-1002"  # Optional metadata
)

# Output structure:
# {
#   qris_id:   "e3b0c44298fc1c149afbf4c8996fb924",
#   qris_code: "00020101021226...",
#   amount:    50000,
#   reference: "ORDER-1002"
# }
```

### Rendering QR Codes in Rails

You can render `qris_data[:qris_code]` using any standard QR code gem, such as `rqrcode`:

```ruby
# In controller:
qrcode = RQRCode::QRCode.new(qris_data[:qris_code])
@svg = qrcode.as_svg(offset: 0, color: "000", shape_rendering: "crispEdges", module_size: 6)

# In view:
# <%= @svg.html_safe %>
```

---

## Transaction Reconciliation

### Initializing the Client

Initialize the client with your stored merchant session:

```ruby
client = Rails::Gopay::Unofficial::Client.new(
  access_token:  session.access_token,
  refresh_token: session.refresh_token,
  merchant_id:   session.merchant_id,
  device_id:     session.device_id,
  expires_at:    session.expires_at # Optional, triggers proactive refresh if <= 15 min
)
```

### Checking Transactions & Matching

`transactions_between` fetches QRIS settlements and captures within a time range, auto-paginating in chunks of 100.

`match_transaction` checks:
1. Status is `SETTLEMENT` or `CAPTURE`.
2. Payment type is `QRIS`.
3. Timestamp falls within `[created_at - 60s, expires_at]`.
4. Transaction gross amount divided by 100 matches the expected IDR integer.

```ruby
# If token was refreshed during calls, persist new tokens:
# client.refresh! updates client.access_token, client.refresh_token, client.expires_at

transactions = client.transactions_between(
  start_time: payment.created_at - 60,
  end_time: Time.now
)

matched = transactions.lazy.filter_map { |txn|
  client.match_transaction(
    txn,
    amount: payment.amount,
    created_at: payment.created_at,
    expires_at: payment.expires_at
  )
}.first

if matched
  # {
  #   transaction_id:   "GO-TXN-12345",
  #   payer_issuer:     "BCA / ShopeePay / GoPay",
  #   transaction_time: 2026-09-23 14:05:12 +0700,
  #   amount:           50000
  # }
  payment.mark_as_paid!(matched)
end
```

### Background Polling Pattern

In production with Solid Queue, Sidekiq, or GoodJob:

```ruby
class CheckGopayPaymentJob < ApplicationJob
  queue_as :default

  def perform(payment_id)
    payment = Payment.find(payment_id)
    return if payment.paid? || payment.expired?

    merchant = payment.merchant
    client = Rails::Gopay::Unofficial::Client.new(
      access_token:  merchant.gopay_access_token,
      refresh_token: merchant.gopay_refresh_token,
      merchant_id:   merchant.gopay_merchant_id,
      device_id:     merchant.gopay_device_id,
      expires_at:    merchant.gopay_token_expires_at
    )

    transactions = client.transactions_between(
      start_time: payment.created_at - 60,
      end_time: Time.now
    )

    # Sync tokens in case client refreshed them
    merchant.update!(
      gopay_access_token: client.access_token,
      gopay_refresh_token: client.refresh_token,
      gopay_token_expires_at: client.expires_at
    ) if client.access_token != merchant.gopay_access_token

    matched = transactions.lazy.filter_map { |txn|
      client.match_transaction(txn, amount: payment.amount, created_at: payment.created_at, expires_at: payment.expires_at)
    }.first

    if matched
      payment.complete_payment!(matched[:transaction_id], matched[:payer_issuer])
    else
      # Re-poll every 5 seconds until expiration
      self.class.set(wait: 5.seconds).perform_later(payment.id)
    end
  end
end
```

---

## Pure QRIS Helper

The `Rails::Gopay::Unofficial::Qris` module provides standalone EMVCo QRIS functions without requiring HTTP or merchant credentials:

```ruby
require "rails/gopay/unofficial/qris"

Qris = Rails::Gopay::Unofficial::Qris

# Validate static QRIS
Qris.valid_static?(static_payload) # => true or false

# Parse EMVCo TLV (Tag-Length-Value) blocks
tags = Qris.parse(payload)
# => [["00", "01"], ["01", "11"], ["51", "0215ID.CO.GOPAY.WWW0118..."], ...]

# Calculate CRC-16 (CCITT-FALSE polynomial 0x1021)
checksum = Qris.crc16("000201010212...6304") # => "ABCD"

# Generate dynamic QRIS string directly
dynamic_code = Qris.generate(static_payload, 75_000)
```

---

## Error Handling

All gem exceptions inherit from `Rails::Gopay::Unofficial::Error`:

```ruby
begin
  client.refresh!
rescue Rails::Gopay::Unofficial::Error => e
  puts "Failed with message: #{e.message}"
  puts "HTTP Status: #{e.status}" if e.status
end
```

Common error cases:
- Missing `device_id` during token refresh (requires OTP re-authentication).
- Expired or invalid OTP code.
- Network timeouts (`Net::OpenTimeout`, `Net::ReadTimeout`).
- Invalid static QRIS template or amount `<=` 0.

---

## Running Tests

Run the test suite using Minitest:

```sh
ruby -Ilib -Itest test/client_test.rb
ruby -Ilib -Itest test/qris_test.rb
```

---

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
