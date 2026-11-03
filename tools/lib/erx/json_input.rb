# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'runner'

module Erx
  # The one parser for JSON that host tooling reads: metadata, records it
  # wrote earlier into the build tree, and output of external tools. It
  # bounds size and depth, requires UTF-8 and finite numbers, and refuses
  # duplicate object keys. Every refusal is an Erx::Error whose message
  # names the input's label but never echoes the input's contents.
  module JsonInput
    # The installed json cannot refuse duplicate keys, so no input is read.
    # This is a fault of the host, not of any input.
    class Unsupported < Error; end

    PARSE_OPTIONS = { max_nesting: 64, allow_duplicate_key: false }.freeze

    # json reports a refused duplicate as a ParserError whose message starts
    # with this text and then quotes the key. This chooses only the wording
    # of a diagnostic: a json that words it differently still refuses the
    # input, which is then reported as malformed.
    def self.duplicate_key_error?(error) = error.message.start_with?('duplicate key')

    # Metadata has one spelling per key. Accepting a duplicate would let the
    # reviewed text disagree with the value a consumer sees, so the json
    # parser refuses it. json ignores options it does not know, so whether
    # this json honors allow_duplicate_key is probed once by behavior, not by
    # version: two objects that differ only in whether a key repeats must be
    # accepted and refused respectively. Any other json makes every parse fail
    # rather than accept duplicates silently.
    def self.refuses_only_duplicate_keys?
      parses?('{"key":0,"other":0}') && !parses?('{"key":0,"key":0}')
    end

    def self.parses?(text)
      JSON.parse(text, **PARSE_OPTIONS)
      true
    rescue JSON::ParserError
      false
    end

    DUPLICATE_KEYS_REFUSED = refuses_only_duplicate_keys?
    private_constant :PARSE_OPTIONS, :DUPLICATE_KEYS_REFUSED
    private_class_method :duplicate_key_error?, :refuses_only_duplicate_keys?, :parses?

    def self.parse(bytes, max_bytes: 16 * 1024 * 1024, label: 'JSON metadata')
      unless DUPLICATE_KEYS_REFUSED
        raise Unsupported, "cannot read #{label}: json #{JSON::VERSION} does not refuse " \
                           'duplicate object keys (allow_duplicate_key)'
      end
      unless bytes.is_a?(String) && bytes.bytesize <= max_bytes
        raise Error, "#{label} exceeds its byte bound"
      end
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, "#{label} is not valid UTF-8" unless text.valid_encoding?
      value = JSON.parse(text, **PARSE_OPTIONS)
      validate_values(value, label: label)
      value
    rescue JSON::ParserError => error
      # Only the kind of failure is kept, so input never reaches a diagnostic.
      kind = duplicate_key_error?(error) ? 'duplicate JSON object key' : 'malformed JSON'
      raise Error, "invalid #{label}: #{kind}"
    end

    def self.validate_values(value, label:)
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
