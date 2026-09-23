# frozen_string_literal: true

module Rails
  module Gopay
    module Unofficial
      module Qris
        module_function

        def generate(template, amount)
          amount = Integer(amount)
          raise Error, "Payment amount must be greater than zero" unless amount.positive?

          tags = parse(template)
          raise Error, "Invalid static QRIS" unless valid_static?(template, tags)

          tags.map! { |tag, value| tag == "01" ? [tag, "12"] : [tag, value] }
          tags.reject! { |tag,| tag == "54" }
          tags.insert(tags.index { |tag,| tag == "58" } || tags.length, ["54", amount.to_s])
          payload = tags.map { |tag, value| "#{tag}#{value.bytesize.to_s.rjust(2, "0")}#{value}" }.join + "6304"
          payload + crc16(payload)
        rescue ArgumentError, TypeError
          raise Error, "Invalid payment amount"
        end

        def parse(payload)
          source = payload.to_s.strip.sub(/6304[0-9A-Fa-f]{4}\z/, "")
          tags = []
          offset = 0
          while offset < source.bytesize
            tag = source.byteslice(offset, 2)
            length = Integer(source.byteslice(offset + 2, 2), 10)
            value = source.byteslice(offset + 4, length)
            return [] unless tag&.match?(/\A\d{2}\z/) && value&.bytesize == length

            tags << [tag, value]
            offset += 4 + length
          end
          tags
        rescue ArgumentError, TypeError
          []
        end

        def crc16(payload)
          crc = payload.each_byte.reduce(0xffff) do |checksum, byte|
            checksum ^= byte << 8
            8.times { checksum = (checksum & 0x8000).zero? ? checksum << 1 : (checksum << 1) ^ 0x1021; checksum &= 0xffff }
            checksum
          end
          crc.to_s(16).upcase.rjust(4, "0")
        end

        def valid_static?(template, tags = parse(template))
          source = template.to_s.strip
          source.match?(/6304[0-9A-Fa-f]{4}\z/) && crc16(source[0...-4]) == source[-4, 4].upcase &&
            tags.assoc("00")&.last == "01" && tags.assoc("01")&.last == "11" &&
            tags.assoc("58")&.last == "ID" && tags.any? { |tag,| (26..51).cover?(tag.to_i) }
        end
      end
    end
  end
end
