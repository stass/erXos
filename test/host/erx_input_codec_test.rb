# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'

# The input records' codec generated from abi/formats/input.txt (docs/design-abi.md,
# "Input records"): the EUnit cases of erx_input_codec on stock's emulator (ERX_ERL
# and ERX_ERLC), the same cases against a codec with one bound check removed, which
# must fail them, and the samples of the declaration the generator refuses, each
# breaking one rule of the grammar.
class ErxInputCodecTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  EMITTER = Erx::ABI::InputEmitter
  MODULE = File.join(Erx::Generated::OUTPUT, EMITTER::ERLANG_PATH)
  TESTS = %w[test/erlang/erx_input_codec_tests.erl].freeze
  # The seeded fault: a touch's slot loses its upper bound.
  SEED = ['Value >= 0 andalso Value =< 9.', 'Value >= 0.'].freeze
  # A declaration the samples below each break in one place.
  SAMPLE = <<~ABI
    input
      record pointer 1 rel
        field dx @input_rel
      record pointer 2 abs
        field x @input_axis
      record touch 3
        field phase @input_touch_phase
      record release 4
  ABI

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_slot_without_its_upper_bound_fails_the_cases
    text = File.read(File.join(ROOT, MODULE))
    assert_equal 1, text.scan(SEED.first).size, 'the seed no longer applies to the generated codec'
    output, status = eunit({ MODULE => text.sub(*SEED) })
    refute status.success?, output
    assert_match(/a_term_past_a_bound_is_no_record_and_does_not_encode_test.*failed/, output)
    assert_match(/each_bad_record_is_dropped_and_counted_and_its_neighbours_kept_test.*failed/, output)
  end

  def test_the_sample_is_accepted
    input = validate(SAMPLE)
    assert_equal [1, 2, 3, 4], input.records.map(&:tag)
    assert_equal 5, input.size
  end

  def test_the_generator_refuses_each_broken_sample
    {
      'a tag 0' => ['record release 4', 'record release 0', /outside/],
      'a tag past a byte' => ['record release 4', 'record release 256', /outside/],
      'a tag used twice' => ['record release 4', 'record release 3', /duplicate input tag 3/],
      'a repeated term' => ['record pointer 2 abs', 'record pointer 2 rel', /repeats an earlier one/],
      'kinds of one name with different words' => ['record pointer 2 abs', 'record pointer 2', /words/],
      'a field of no root type' => ['field x @input_axis', 'field x @input_nothing', /not a root scalar or enum/],
      'a field of a bare base type' => ['field x @input_axis', 'field x u16', /not a root scalar or enum/],
      'a field name with an underscore' => ['field x @input_axis', 'field x_y @input_axis', /invalid input field name/],
      'a field named twice' => ['field dx @input_rel', "field dx @input_rel\n    field dx @input_rel", /duplicate input field/],
      'an unknown member' => ['record release 4', 'message release 4', /unknown input member/],
      'an argument' => ["input\n", "input 1\n", /expected input/]
    }.each do |label, (text, broken, message)|
      assert_includes SAMPLE, text, label
      error = assert_raises(Erx::ABI::SchemaError, label) { validate(SAMPLE.sub(text, broken)) }
      assert_match message, error.message, label
    end
  end

  def test_a_second_declaration_or_one_elsewhere_is_refused
    assert_raises(Erx::ABI::SchemaError) { validate(SAMPLE + SAMPLE) }
    error = assert_raises(Erx::ABI::SchemaError) { validate(SAMPLE, path: 'abi/formats/ui.txt') }
    assert_match(/belongs in abi\/formats\/input.txt/, error.message)
  end

  def test_generated_output_is_deterministic
    first, second = Array.new(2) { Erx::ABI::Generator.plan(root: ROOT).files.fetch(EMITTER::ERLANG_PATH) }
    assert_equal first, second
    assert_equal File.read(File.join(ROOT, MODULE)), first
  end

  private

  def root_types = @root_types ||= Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)).types

  def validate(text, path: Erx::ABI::Input::SOURCE)
    declarations = Erx::ABI::Syntax.parse(text, path: path).select { |declaration| declaration.kind == 'input' }
    Erx::ABI::Input.validate(declarations, types: root_types)
  end

  # Runs the EUnit cases against erx with the given sources replaced; the output and status.
  def eunit(replaced)
    Dir.mktmpdir('erx-input-codec-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_input_codec_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
