# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'runner'

module Erx
  module JsonInput
    # Metadata has one spelling per key. Silently replacing a duplicate would
    # make the reviewed input disagree with the value a consumer sees.
    class UniqueObject < Hash
      def []=(key, value)
        raise Error, 'duplicate JSON object key' if key?(key)
        super
      end
    end
    private_constant :UniqueObject
    module_function

    def parse(bytes, max_bytes: 16 * 1024 * 1024, label: 'JSON metadata')
      unless bytes.is_a?(String) && bytes.bytesize <= max_bytes
        raise Error, "#{label} exceeds its byte bound"
      end
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, "#{label} is not valid UTF-8" unless text.valid_encoding?
      value = JSON.parse(text, max_nesting: 64, object_class: UniqueObject)
      validate_values(value, label: label)
      value
    rescue JSON::ParserError
      raise Error, "invalid #{label}: malformed JSON"
    end

    def validate_values(value, label:)
      pending = [value]
      until pending.empty?
        item = pending.pop
        case item
        when Hash
          item.each do |key, member|
            raise Error, "#{label} has an invalid UTF-8 key" unless key.valid_encoding?
            pending << member
          end
        when Array
          pending.concat(item)
        when String
          raise Error, "#{label} has an invalid UTF-8 value" unless item.valid_encoding?
        when Float
          raise Error, "#{label} has a non-finite number" unless item.finite?
        end
      end
    end
    private_class_method :validate_values
  end
end
