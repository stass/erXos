# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/json_input'

class JsonInputTest < Minitest::Test
  def test_invalid_encoding_and_duplicate_keys_are_diagnostics
    assert_raises(Erx::Error) { Erx::JsonInput.parse("{\"key\":\"\xff\"}".b) }
    assert_raises(Erx::Error) { Erx::JsonInput.parse('{"key":1,"key":2}') }
  end

  def test_depth_byte_and_number_bounds
    assert_raises(Erx::Error) { Erx::JsonInput.parse('[' * 65 + '0' + ']' * 65) }
    assert_raises(Erx::Error) { Erx::JsonInput.parse('{"key":1}', max_bytes: 2) }
    assert_raises(Erx::Error) { Erx::JsonInput.parse('1e9999') }
  end

  def test_plain_typed_values_are_preserved
    result = Erx::JsonInput.parse('{"key":[1,true,null,"value"]}')
    assert_equal({ 'key' => [1, true, nil, 'value'] }, result)
  end

  def test_malformed_json_diagnostic_does_not_echo_input_contents
    secret = 'private-token-that-must-not-appear'
    error = assert_raises(Erx::Error) { Erx::JsonInput.parse("{#{secret}", label: 'build record') }
    assert_includes error.message, 'build record'
    refute_includes error.message, secret
  end
end
