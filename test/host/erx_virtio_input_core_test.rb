# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_virtio_input_core_tests.erl, the cases of the virtio-input driver's
# pure core, against erx_virtio_input_core compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault, applied to a
# copy of the module, must fail the case named for it: an event value read unsigned, which
# turns a move left into one of four billion pixels right, and a keyboard identified from
# a mouse's buttons, which would route a pointer's clicks as key presses.
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
             anchor: 'Code > 0 andalso Code < ?ERX_EVDEV_BTN_MISC',
             replacement: 'Code > 0 andalso Code =< ?ERX_EVDEV_KEY_MAX',
             catching_case: 'buttons_alone_make_no_keyboard_test')
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
      assert_match(/#{Regexp.escape(seed.catching_case)}.*\*failed\*/m, output, seed.fault)
    end
  end

  private

  # The module's text compiled in place of the application's own, then the cases.
  def run_cases(module_text)
    Dir.mktmpdir('erx-virtio-input-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_virtio_input_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
