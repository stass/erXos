# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pixels_core_tests.erl, the cases of the pixel allocator's pure
# core (docs/design-display.md, "The pixel area", The allocator's core, and
# Verification), against erx_pixels_core compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault the design
# names, applied to a copy of the module, must fail the case named for it. The seeded
# runs are independent, so they run at once.
class ErxPixelsCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_display].freeze
  MODULE = 'erlang/apps/erx_display/src/erx_pixels_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_pixels_core_tests.erl].freeze
  DEADLINE_SECONDS = '300'

  # A seeded fault: its edits, each an anchor found once in the module and its replacement.
  Seed = Data.define(:fault, :edits, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a free list that does not join neighbours',
             edits: [['join({Start, Pages + More}, Rest);', '[{Start, Pages}, {Next, More} | Rest];'],
                     ['join({Prev, Before + Pages}, Rest);', '[{Prev, Before} | join({Start, Pages}, Rest)];']],
             catching_case: 'random_sequences_test_'),
    Seed.new(fault: "a core that frees a lent range at its owner's exit",
             edits: [['owner_gone({Start, #range{lease = none, pages = Pages}}, ', 'owner_gone({Start, #range{pages = Pages}}, ']],
             catching_case: 'random_sequences_test_'),
    Seed.new(fault: 'a core that joins before the zero',
             edits: [['{Core#core{zeroing = Zeroing#{Start => Pages}}, [{zero, Start * ?PAGE, Pages}]}.',
                      '{Core#core{zeroing = Zeroing#{Start => Pages}, free = join({Start, Pages}, Core#core.free)}, ' \
                      '[{zero, Start * ?PAGE, Pages}]}.'],
                     ['free = join({Start, Pages}, Free)}.', 'free = Free}.']],
             catching_case: 'random_sequences_test_')
  ].freeze

  def test_core_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    runs = SEEDS.map do |seed|
      seeded = seed.edits.reduce(source) do |text, (anchor, replacement)|
        assert_equal 1, text.scan(anchor).size, "anchor for #{seed.fault} is not once in #{MODULE_SOURCE}: #{anchor}"
        text.sub(anchor, replacement)
      end
      Thread.new { [seed, *eunit(seeded)] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_match(failed_case(seed.catching_case), output, "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  # EUnit names a plain case by its function and a generator's case by the fun inside it.
  def failed_case(name) = %r{#{Regexp.escape(name)}(/0-fun-\d+-)?\.\.\.(\[[^\]]*\] )?\*failed\*}

  def eunit(module_text)
    Dir.mktmpdir('erx-pixels-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_pixels_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
