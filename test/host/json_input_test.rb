# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require_relative '../../tools/lib/erx/json_input'

class JsonInputTest < Minitest::Test
  JSON_INPUT = File.expand_path('../../tools/lib/erx/json_input.rb', __dir__)

  # A child process stands in for another json, named by its second argument:
  # 'optionless' ignores allow_duplicate_key, as a json without the option
  # does, and keeps the last duplicate; 'refuses-objects' refuses every object
  # with json's duplicate-key error, so refusing the probe's duplicate proves
  # nothing; 'reworded' refuses duplicates with a differently worded error.
  # The child prints how JsonInput reads one object without and one with a
  # duplicate key.
  STAND_IN_JSON_CHILD = <<~'CHILD'
    require 'json'
    module StandInParse
      def parse(source, options = nil)
        mode = ARGV.fetch(1)
        raise JSON::ParserError, 'duplicate key "key"' if mode == 'refuses-objects'
        options = (options || {}).reject { |key, _| key == :allow_duplicate_key } if mode == 'optionless'
        super(source, options)
      rescue JSON::ParserError => error
        raise if mode != 'reworded'
        raise JSON::ParserError, error.message.sub('duplicate key', 'repeated name')
      end
    end
    JSON.singleton_class.prepend(StandInParse)
    require ARGV.fetch(0)
    ['{"key":1}', '{"key":1,"key":2}'].each do |text|
      puts Erx::JsonInput.parse(text).inspect
    rescue Erx::Error => error
      puts "#{error.class}: #{error.message}"
    end
  CHILD

  def stand_in_reads(mode)
    # Only standard output is read: json may warn about the probe's duplicate
    # on standard error.
    output, errors, status = Open3.capture3(RbConfig.ruby, '-e', STAND_IN_JSON_CHILD, JSON_INPUT, mode,
                                            stdin_data: '')
    assert status.success?, errors
    output.lines(chomp: true)
  end

  def test_invalid_encoding_and_duplicate_keys_are_diagnostics
    assert_raises(Erx::Error) { Erx::JsonInput.parse("{\"key\":\"\xff\"}".b) }
    assert_raises(Erx::Error) { Erx::JsonInput.parse('{"key":1,"key":2}') }
  end

  def test_duplicate_keys_are_refused_at_any_depth_and_in_any_spelling
    ['{"outer":{"key":1,"key":2}}', '[{"key":1,"key":2}]', '{"key":1,"k\\u0065y":2}'].each do |text|
      error = assert_raises(Erx::Error) { Erx::JsonInput.parse(text, label: 'build record') }
      assert_equal 'invalid build record: duplicate JSON object key', error.message
    end
  end

  def test_duplicate_key_diagnostic_does_not_echo_the_key
    secret = 'private-token-that-must-not-appear'
    error = assert_raises(Erx::Error) { Erx::JsonInput.parse("{\"#{secret}\":1,\"#{secret}\":2}") }
    refute_includes error.message, secret
  end

  def test_json_that_cannot_refuse_duplicate_keys_refuses_every_input
    unsupported = /\AErx::JsonInput::Unsupported: cannot read JSON metadata: json \S+ does not refuse duplicate/
    %w[optionless refuses-objects].each do |mode|
      reads = stand_in_reads(mode)
      assert_equal 2, reads.size, mode
      reads.each { |read| assert_match unsupported, read, mode }
    end
  end

  def test_json_that_rewords_its_duplicate_key_error_still_refuses_duplicates
    assert_equal ['{"key" => 1}', 'Erx::Error: invalid JSON metadata: malformed JSON'], stand_in_reads('reworded')
  end

  def test_depth_byte_and_number_bounds
    assert_raises(Erx::Error) { Erx::JsonInput.parse('[' * 65 + '0' + ']' * 65) }
    assert_raises(Erx::Error) { Erx::JsonInput.parse('{"key":1}', max_bytes: 2) }
    assert_raises(Erx::Error) { Erx::JsonInput.parse('1e9999') }
  end

  def test_plain_typed_values_are_preserved
    result = Erx::JsonInput.parse('{"key":[1,true,null,"value"],"Key":{}}')
    assert_equal({ 'key' => [1, true, nil, 'value'], 'Key' => {} }, result)
    assert_instance_of Hash, result
  end

  def test_malformed_json_diagnostic_does_not_echo_input_contents
    secret = 'private-token-that-must-not-appear'
    error = assert_raises(Erx::Error) { Erx::JsonInput.parse("{#{secret}", label: 'build record') }
    assert_equal 'invalid build record: malformed JSON', error.message
    refute_includes error.message, secret
  end
end
