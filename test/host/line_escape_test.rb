# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/json_input'
require_relative '../../tools/lib/erx/line_escape'

# The host tool's line escape against the vectors erx_text answers too
# (test/erlang/erx_text_tests.erl), one or more per character class of
# abi/terminal.txt, and against the properties every output must have.
class LineEscapeTest < Minitest::Test
  VECTORS = Erx::JsonInput.parse(File.binread(File.expand_path('../fixtures/line_escape_vectors.json', __dir__)),
                                 label: 'line escape vectors').fetch('vectors').freeze

  def test_every_class_renders_as_the_shared_vectors_say
    VECTORS.each do |vector|
      input = [vector.fetch('input')].pack('H*')
      assert_equal vector.fetch('line'), Erx::LineEscape.escape(input), vector.fetch('class')
    end
  end

  def test_output_is_valid_utf8_with_no_unsafe_character
    random = Random.new(7)
    500.times do
      output = Erx::LineEscape.escape(random.bytes(random.rand(0..64)))
      assert output.valid_encoding?
      assert_equal Encoding::UTF_8, output.encoding
      refute output.each_char.any? { |character| unsafe?(character.ord) }, output.dump
      assert_equal output, Erx::LineEscape.escape(output)
    end
  end

  def test_the_encoding_a_string_claims_does_not_matter
    assert_equal '<0xFF><U+001B>', Erx::LineEscape.escape("\xff\e".dup.force_encoding(Encoding::ISO_8859_1))
    assert_equal '42', Erx::LineEscape.escape(42)
  end

  private

  def unsafe?(point)
    Erx::Generated::TerminalTables::UNICODE_UNSAFE_RANGES.any? { |first, last| point.between?(first, last) }
  end
end
