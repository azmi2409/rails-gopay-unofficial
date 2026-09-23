# frozen_string_literal: true

module Rails
  module Gopay
    module Unofficial
      class Error < StandardError
        attr_reader :status

        def initialize(message, status = nil)
          @status = status
          super(message)
        end
      end
    end
  end
end
