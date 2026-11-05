# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The event table's core and its sleep step (test/fixtures/runtime_event_harness.c), under
# ThreadSanitizer and the other sanitizers, and with the seeded lost wake, which must show.
class RuntimeEventTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  HARNESS = File.join(ROOT, 'test/fixtures/runtime_event_harness.c')
  CORE = File.join(ROOT, 'otp/erts/emulator/sys/erxos/erx_event_table.c')
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g', '-pthread',
           '-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'otp/erts/emulator/sys/erxos'),
           '-DERX_EVENT_TEST_GAP(n)=erx_event_test_gap(n)'].freeze
  BUDGET_SECONDS = '120'

  def test_no_fire_is_lost_under_thread_sanitizer
    output, status = run_harness('-fsanitize=thread')
    assert status.success?, output
    assert_match(/^event table done$/, output)
  end

  def test_the_table_is_clean_under_address_and_undefined_sanitizers
    output, status = run_harness('-fsanitize=address,undefined', '-fno-sanitize-recover=undefined')
    assert status.success?, output
    assert_match(/^event table done$/, output)
  end

  def test_the_seeded_order_loses_a_wake
    output, status = run_harness('-DERX_EVENT_SEED_LOOK_BEFORE_EPOCHS')
    refute status.success?, output
    assert_match(/^LOST WAKE: fire at gap 1: /, output)
  end

  private

  def run_harness(*extra)
    Dir.mktmpdir('erx-event-') do |directory|
      binary = File.join(directory, 'harness')
      log, built = Open3.capture2e('clang', *FLAGS, *extra, HARNESS, CORE, '-o', binary, stdin_data: '')
      assert built.success?, log
      Open3.capture2e({ 'TSAN_OPTIONS' => 'halt_on_error=1' }, 'gtimeout', '-k', '5', BUDGET_SECONDS, binary, stdin_data: '')
    end
  end
end
