# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "time"

module Rails
  module Gopay
    module Unofficial
      class Configuration
        attr_accessor :phone_number, :static_qris
      end

      class << self
        def configuration
          @configuration ||= Configuration.new
        end

        def configure
          yield configuration
        end
      end
    end
  end
end

require_relative "unofficial/error"
require_relative "unofficial/qris"
require_relative "unofficial/client"
require_relative "unofficial/setup"
