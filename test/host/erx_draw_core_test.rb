# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_draw_core_tests.erl, the exploration of the draw
# protocol's pure core and its plan/2 cases, against erx_draw_core, the
# generated erx_draw_codec and erx_draw_image compiled on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault
# of docs/design-display.md's "Verification and testing", applied to a copy
# of erx_draw_core, must fail the case named for it.
class ErxDrawCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_display/src/erx_draw_core.erl')
  OTHER_SOURCES = [File.join(ROOT, Erx::Generated::OUTPUT, Erx::ABI::DrawEmitter::ERLANG_PATH),
                   File.join(ROOT, 'erlang/apps/erx_display/src/erx_draw_image.erl'),
                   File.join(ROOT, 'test/erlang/erx_draw_core_tests.erl')].freeze
  DEADLINE_SECONDS = '600'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the quota check skipped',
             anchor: 'ok ?= check(Charged =< Quota, enomem),',
             replacement: 'ok ?= check(true, enomem),',
             catching_case: 'exploration_test_'),
    # Every plan_test_ case plans from a new connection with the window
    # this seed names, so its depths are those of the connection before the
    # write.
    Seed.new(fault: 'a plan that frames with the depths of the connection as it stood before the write',
             anchor: 'erx_draw_codec:decode(Bytes, depth_fun(State)),',
             replacement: 'erx_draw_codec:decode(Bytes, depth_fun(new(#{r => {0, 0, 4, 4}, chan => 16#48081828, ' \
                          'quota => #{pixels => 0, side => 1}}))),',
             catching_case: 'plan_test_')
  ].freeze

  def test_core_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE), warnings_as_errors: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "anchor for #{seed.fault} is not once in #{MODULE_SOURCE}"
    end
    runs = SEEDS.map do |seed|
      Thread.new { [seed, *eunit(source.sub(seed.anchor, seed.replacement), warnings_as_errors: false)] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_match(failed_case(seed.catching_case), output, "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  # EUnit names a plain case by its function and a generator's case by the fun inside it.
  def failed_case(name) = %r{#{Regexp.escape(name)}(/0-fun-\d+-)?\.\.\.(\[[^\]]*\] )?\*failed\*}

  def eunit(module_text, warnings_as_errors:)
    Dir.mktmpdir('erx-draw-core-test') do |work|
      module_path = File.join(work, 'erx_draw_core.erl')
      File.binwrite(module_path, module_text)
      flags = warnings_as_errors ? ['-Werror'] : []
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, '-o', work, module_path, *OTHER_SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_draw_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
