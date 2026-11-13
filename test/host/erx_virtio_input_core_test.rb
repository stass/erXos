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
# copy of the module, must fail the case named for it: an event value read unsigned, which
# turns a move left into one of four billion pixels right, and a keyboard identified from
# a mouse's buttons, which would route a pointer's clicks as key presses.
#
# The module takes every evdev code from abi/formats/evdev.txt, while the cases write
# each code out as a number. So one more seeded fault edits a copy of the table instead
# of the module: REL_WHEEL given REL_HWHEEL's code, with erx_abi.hrl generated again
# from that copy, must fail the case that turns a wheel.
class ErxVirtioInputCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding the module, compiled whole with those it depends on (ErlangBuild), the module and the cases.
  APPLICATIONS = %w[erx_fb].freeze
  MODULE = 'erlang/apps/erx_fb/src/erx_virtio_input_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_virtio_input_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'an event value read unsigned',
             anchor: 'Value:32/little-signed>>) -> typed(Type, Code, Value);',
             replacement: 'Value:32/little>>) -> typed(Type, Code, Value);',
             catching_case: 'relative_moves_are_signed_test'),
    Seed.new(fault: "a keyboard identified from a mouse's buttons",
             anchor: 'Code > ?ERX_EVDEV_KEY_RESERVED andalso Code < ?ERX_EVDEV_BTN_MISC',
             replacement: 'Code > ?ERX_EVDEV_KEY_RESERVED andalso Code =< ?ERX_EVDEV_KEY_MAX',
             catching_case: 'buttons_alone_make_no_keyboard_test')
  ].freeze

  TABLE = 'abi/formats/evdev.txt'
  TABLE_SEED = Seed.new(fault: "the wheel read from the horizontal wheel's code",
                        anchor: 'limit evdev_rel_wheel u16 0x08',
                        replacement: 'limit evdev_rel_wheel u16 0x06',
                        catching_case: 'relative_moves_are_signed_test')

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

  def test_a_code_changed_in_the_evdev_table_fails_its_case
    Dir.mktmpdir('erx-virtio-input-core-abi') do |root|
      directory = seeded_header(root, TABLE_SEED)
      output, status = run_cases(File.binread(MODULE_SOURCE), includes: [directory])
      refute status.success?, "#{TABLE_SEED.fault}: the cases passed"
      assert_case_failed(output, TABLE_SEED)
    end
  end

  private

  # eunit's verbose line for the seed's catching case reports it failed; another case's
  # failure further on does not count.
  def assert_case_failed(output, seed)
    assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
  end

  # Copies abi/ under root, applies seed to the copy's evdev table and writes the
  # erx_abi.hrl generated from it to root/include/generated/, the path the module's
  # -include("generated/erx_abi.hrl") names. Returns root/include, the directory to
  # search first.
  def seeded_header(root, seed)
    FileUtils.cp_r(File.join(ROOT, 'abi'), root)
    table = File.join(root, TABLE)
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
