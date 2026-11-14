# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/abi'

# Runs test/erlang/erx_virtio_input_core_tests.erl, the cases of the virtio-input driver's
# pure core, against erx_virtio_input_core compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault, applied to a
# copy of the module, must fail the case named for it (docs/design-display.md,
# "Verification and testing", Drivers): an event value read unsigned, which turns a move
# left into one of four billion pixels right; a fold that forwards the device's repeats,
# which the router makes itself; one that resumes at once after SYN_DROPPED, folding the
# tail of an update whose start is lost; one that sends a press before the moves ahead of
# it, so it lands where the pointer was; one that sums moves without its range check, so
# a sum overflows a record; and one that normalizes over one step too many, so an axis's
# maximum falls short of the record's.
#
# The module takes every evdev code from abi/formats/evdev.txt and a record's bounds from
# abi/formats/input.txt, while the cases write each number out. So two more seeded faults
# edit a copy of a table instead of the module, with erx_abi.hrl generated again from that
# copy: REL_WHEEL given REL_HWHEEL's code must fail the case that turns a wheel, and a
# wheel's record range widened must fail the case that clamps one.
class ErxVirtioInputCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding the module, compiled whole with those it depends on (ErlangBuild), the module and the cases.
  APPLICATIONS = %w[erx_fb].freeze
  MODULE = 'erlang/apps/erx_fb/src/erx_virtio_input_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_virtio_input_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)
  TableSeed = Data.define(:table, :seed)

  SEEDS = [
    Seed.new(fault: 'an event value read unsigned',
             anchor: 'Value:32/little-signed>>) -> typed(Type, Code, Value);',
             replacement: 'Value:32/little>>) -> typed(Type, Code, Value);',
             catching_case: 'relative_moves_are_signed_test'),
    Seed.new(fault: "a fold that forwards the device's repeats",
             anchor: "step({ok, {key, _, repeat}}, F) -> {[], count(unused, F)};\n",
             replacement: '',
             catching_case: 'a_repeat_sends_nothing_test'),
    Seed.new(fault: 'a fold that resumes at once after SYN_DROPPED',
             anchor: '#fold{axes = Axes, counts = Counts, phase = skipping}',
             replacement: '#fold{axes = Axes, counts = Counts, phase = folding}',
             catching_case: 'syn_dropped_sends_release_and_skips_to_the_next_report_test'),
    Seed.new(fault: 'a press sent before the moves ahead of it',
             anchor: '{Kept ++ [{key, Edge, Code}], Next}',
             replacement: '{[{key, Edge, Code} | Kept], Next}',
             catching_case: 'a_press_lands_after_the_moves_before_it_test'),
    Seed.new(fault: 'a fold that sums moves without its range check',
             anchor: 'case is_rel(SX + DX) andalso is_rel(SY + DY) of',
             replacement: 'case true of',
             catching_case: 'two_moves_of_the_range_maximum_are_sent_as_two_test'),
    Seed.new(fault: 'a position normalized over one step too many',
             anchor: '* ?ERX_INPUT_AXIS_MAX div (Max - Min).',
             replacement: '* ?ERX_INPUT_AXIS_MAX div (Max - Min + 1).',
             catching_case: 'an_axis_minimum_and_maximum_normalize_to_0_and_65535_test'),
    Seed.new(fault: "an axis bound read from its register unsigned",
             anchor: '<<Value:32/signed>> = <<Word:32>>,',
             replacement: '<<Value:32>> = <<Word:32>>,',
             catching_case: 'absinfo_is_a_whole_answer_with_min_below_max_test')
  ].freeze

  TABLE_SEEDS = [
    TableSeed.new(table: 'abi/formats/evdev.txt',
                  seed: Seed.new(fault: "the wheel read from the horizontal wheel's code",
                                 anchor: 'limit evdev_rel_wheel u16 0x08',
                                 replacement: 'limit evdev_rel_wheel u16 0x06',
                                 catching_case: 'wheel_steps_are_clamped_then_summed_test')),
    TableSeed.new(table: 'abi/formats/input.txt',
                  seed: Seed.new(fault: "a wheel's record range widened",
                                 anchor: 'limit input_wheel_max i32 127',
                                 replacement: 'limit input_wheel_max i32 255',
                                 catching_case: 'wheel_steps_are_clamped_then_summed_test'))
  ].freeze

  def test_virtio_input_core_cases_pass_under_eunit
    output, status = run_cases(File.binread(MODULE_SOURCE))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(source.sub(seed.anchor) { seed.replacement })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_case_failed(output, seed)
    end
  end

  def test_a_value_changed_in_a_table_fails_its_case
    TABLE_SEEDS.each do |table_seed|
      Dir.mktmpdir('erx-virtio-input-core-abi') do |root|
        directory = seeded_header(root, table_seed)
        output, status = run_cases(File.binread(MODULE_SOURCE), includes: [directory])
        refute status.success?, "#{table_seed.seed.fault}: the cases passed"
        assert_case_failed(output, table_seed.seed)
      end
    end
  end

  private

  # eunit's verbose line for the seed's catching case reports it failed; another case's
  # failure further on does not count.
  def assert_case_failed(output, seed)
    assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
  end

  # Copies abi/ under root, applies the seed to the copy's table and writes the
  # erx_abi.hrl generated from it to root/include/generated/, the path the module's
  # -include("generated/erx_abi.hrl") names. Returns root/include, the directory to
  # search first.
  def seeded_header(root, table_seed)
    seed = table_seed.seed
    FileUtils.cp_r(File.join(ROOT, 'abi'), root)
    table = File.join(root, table_seed.table)
    text = File.binread(table)
    assert_equal 1, text.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
    File.binwrite(table, text.sub(seed.anchor) { seed.replacement })
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    File.join(root, 'include').tap do |directory|
      FileUtils.mkdir_p(File.join(directory, 'generated'))
      File.write(File.join(directory, 'generated', 'erx_abi.hrl'), Erx::ABI::ErlangEmitter.header(schema))
    end
  end


  # The module's text compiled in place of the application's own, then the cases; includes
  # are searched for its headers before the build's own.
  def run_cases(module_text, includes: [])
    Dir.mktmpdir('erx-virtio-input-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text },
                                includes: includes)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_virtio_input_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
