# frozen_string_literal: true

module Rails
  module Gopay
    module Unofficial
      module Response
        module_function

        def data(payload)
          return {} unless payload.is_a?(Hash)

          inner = payload[:data]
          inner.is_a?(Hash) ? inner : payload
        end

        def error(payload)
          return nil unless payload.is_a?(Hash)

          description = payload[:error_description] || payload.dig(:data, :error_description)
          errors = payload[:errors] || payload[:error] || payload.dig(:data, :errors) || payload.dig(:data, :error)
          messages = extract(errors)
          messages << description.to_s unless description.to_s.empty?
          return nil if messages.empty?

          messages.uniq.join("; ")
        end

        def extract(errors)
          case errors
          when nil then []
          when Array then errors.filter_map { |item| item.is_a?(Hash) ? (item[:message] || item[:code]) : item.to_s }
          when Hash then [errors[:message] || errors[:code]]
          else [errors.to_s]
          end.reject(&:empty?)
        end
        private_class_method :extract
      end
    end
  end
end
