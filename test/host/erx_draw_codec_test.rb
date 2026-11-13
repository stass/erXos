# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'

# The draw codec generated from abi/formats/draw.txt (docs/design-display.md,
# "Draw messages"): the EUnit cases of erx_draw_codec and erx_draw_image on
# stock's emulator (ERX_ERL and ERX_ERLC), and the differential test of the
# Erlang codec against its C twin, built under ASan and UBSan with the
# framing of compressed pixels in test/fixtures/erx_draw_cload.c. Over one
# corpus, valid and broken, the two must decode the same message to the same
# next offset, or fail with the same errno at the same offset, message by
# message; a twin seeded with an off-by-one in a length must not.
class ErxDrawCodecTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  GENERATED = File.join(ROOT, Erx::Generated::OUTPUT)
  EMITTER = Erx::ABI::DrawEmitter
  APPLICATIONS = %w[erx_display].freeze
  TESTS = %w[test/erlang/erx_draw_codec_tests.erl].freeze
  HARNESS = %w[test/fixtures/erx_draw_codec_harness.c test/fixtures/erx_draw_cload.c].map { |path| File.join(ROOT, path) }
  # The seeded fault: indices take one byte more than their count's.
  SEED = ['value->length = *used = (size_t)value->count * 2;', 'value->length = *used = (size_t)value->count * 2 + 1;'].freeze

  def test_eunit_cases_pass
    in_erlang do |work|
      output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                    'halt(case eunit:test(erx_draw_codec_tests, [verbose]) of ok -> 0; _ -> 1 end)', chdir: work)
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_erlang_codec_and_c_twin_agree_on_the_corpus
    in_erlang do |work|
      corpus, expected = corpus(work)
      lines = run!(harness(work, File.binread(c_source)), corpus, chdir: work).lines(chomp: true)
      assert_equal expected, lines
      %w[error\ einval error\ enoent cload\  load\  poly\  string_bg\ ].each do |start|
        assert_operator lines.count { |line| line.start_with?(start) }, :>, 20, start
      end
    end
  end

  def test_a_seeded_off_by_one_in_a_length_fails_the_agreement
    source = File.binread(c_source)
    assert source.include?(SEED.first), 'the seed no longer applies to the generated twin'
    in_erlang do |work|
      corpus, expected = corpus(work)
      seeded = harness(work, source.sub(SEED.first, SEED.last), name: 'seeded')
      refute_equal expected, run!(seeded, corpus, chdir: work).lines(chomp: true)
    end
  end

  def test_generated_output_is_deterministic
    first, second = Array.new(2) { Erx::ABI::Generator.plan(root: ROOT).files }
    [EMITTER::ERLANG_PATH, EMITTER::C_HEADER_PATH, EMITTER::C_SOURCE_PATH].each do |path|
      assert_equal first.fetch(path), second.fetch(path), path
      assert_equal File.binread(File.join(GENERATED, path)), first.fetch(path), path
    end
  end

  private

  def c_source = File.join(GENERATED, EMITTER::C_SOURCE_PATH)

  # The corpus and the Erlang codec's lines for it.
  def corpus(work)
    corpus = File.join(work, 'corpus')
    lines = File.join(work, 'lines')
    run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
         "erx_draw_codec_tests:corpus(\"#{corpus}\", 7, 3000), erx_draw_codec_tests:decode_corpus(\"#{corpus}\", " \
         "\"#{lines}\"), halt(0)", chdir: work)
    [corpus, File.readlines(lines, chomp: true)]
  end

  # The harness, built with the given twin source under ASan and UBSan.
  def harness(work, twin, name: 'harness')
    source = File.join(work, "#{name}_twin.c")
    File.binwrite(source, twin)
    File.join(work, name).tap do |binary|
      run!(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-I', File.join(GENERATED, 'include'),
           *HARNESS, source, '-o', binary, chdir: work)
    end
  end

  def in_erlang
    Dir.mktmpdir('erx-draw-codec-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      yield work
    end
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
