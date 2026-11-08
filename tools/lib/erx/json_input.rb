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

    # Raised by DistinctKeys when an object repeats a key. It is a
    # JSON::ParserError so that it leaves the parser the way json's own
    # refusal does, and its message never quotes the key.
    class DuplicateKey < JSON::ParserError
      def initialize = super('duplicate key')
    end

    # The object class json builds each parsed object from. A json that
    # calls []= once per member (json 2.9 does) refuses a repeated key here.
    # The result is converted to a plain Hash before it is returned.
    class DistinctKeys < Hash
      def []=(key, value)
        raise DuplicateKey if key?(key)

        super
      end
    end
    private_constant :DuplicateKey, :DistinctKeys

    # Both mechanisms are always requested, and a given json honors at most
    # one of them: json 2.13 and later refuse a duplicate themselves
    # (allow_duplicate_key) and ignore what object_class would see, while
    # json 2.9 ignores that option and refuses through DistinctKeys. No
    # mechanism is selected by version.
    # The deepest nesting a caller may ask for: plain_checked recurses once
    # per level, well within Ruby's stack at this depth.
    MAX_NESTING = 1024
    PARSE_OPTIONS = { max_nesting: 64, allow_duplicate_key: false, object_class: DistinctKeys }.freeze

    # json reports its own refused duplicate as a ParserError whose message
    # starts with this text and then quotes the key. This chooses only the
    # wording of a diagnostic: a json that words it differently still refuses
    # the input, which is then reported as malformed.
    def self.duplicate_key_error?(error) = error.message.start_with?('duplicate key')

    # Metadata has one spelling per key. Accepting a duplicate would let the
    # reviewed text disagree with the value a consumer sees. json ignores
    # options it does not know, so whether some mechanism above works is
    # probed once by behavior, not by version: two objects that differ only
    # in whether a key repeats must be accepted and refused respectively.
    # If this json refuses neither way, every parse fails rather than accept
    # duplicates silently.
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

    # max_nesting is raised only for a tool whose output nests deeply by
    # nature, as a syntax tree does.
    def self.parse(bytes, max_bytes: 16 * 1024 * 1024, max_nesting: PARSE_OPTIONS.fetch(:max_nesting),
                   label: 'JSON metadata')
      unless DUPLICATE_KEYS_REFUSED
        raise Unsupported, "cannot read #{label}: json #{JSON::VERSION} does not refuse " \
                           'duplicate object keys (allow_duplicate_key)'
      end
      unless max_nesting.is_a?(Integer) && max_nesting.between?(1, MAX_NESTING)
        raise Error, "#{label}: nesting bound must be an integer from 1 to #{MAX_NESTING}"
      end
      unless bytes.is_a?(String) && bytes.bytesize <= max_bytes
        raise Error, "#{label} exceeds its byte bound"
      end
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, "#{label} is not valid UTF-8" unless text.valid_encoding?
      plain_checked(JSON.parse(text, **PARSE_OPTIONS, max_nesting: max_nesting), label: label)
    rescue JSON::ParserError => error
      # Only the kind of failure is kept, so input never reaches a diagnostic.
      kind = duplicate_key_error?(error) ? 'duplicate JSON object key' : 'malformed JSON'
      # cause: nil drops the parser's error, which quotes the input.
      raise Error, "invalid #{label}: #{kind}", cause: nil
    end

    # Checks every string and number and returns the same value with each
    # object turned into a plain Hash, so callers never see DistinctKeys
    # and a later assignment to a key cannot raise. The parser's max_nesting
    # bounds the recursion.
    def self.plain_checked(value, label:)
      case value
      when Hash
        value.to_h do |key, member|
          raise Error, "#{label} has an invalid UTF-8 key" unless key.valid_encoding?

          [key, plain_checked(member, label: label)]
        end
      when Array
        value.map { |member| plain_checked(member, label: label) }
      when String
        raise Error, "#{label} has an invalid UTF-8 value" unless value.valid_encoding?

        value
      when Float
        raise Error, "#{label} has a non-finite number" unless value.finite?

        value
      else
        value
      end
    end
    private_class_method :plain_checked
  end
end
