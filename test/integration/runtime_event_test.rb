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

  def test_the_epochs_read_after_the_flag_lose_a_waker
    output, status = run_harness('-DERX_EVENT_SEED_EPOCHS_AFTER_FLAG')
    refute status.success?, output
    assert_match(/^LOST WAKE: waker at point 4: /, output)
  end

  def test_the_seeded_exit_leaves_with_a_label
    output, status = run_harness('-DERX_EVENT_SEED_LEAVE_WITHOUT_TAKING')
    refute status.success?, output
    assert_match(/^LEFT WITH A LABEL: fire at gap 0, flag set$/, output)
  end

  # The harness drives the core's exit; this ties it to the wait itself, whose loop is ERTS's
  # and runs only in the hosted runtime. It reads text, so it pins the call's place and
  # cannot tell a call from a comment.
  def test_scheduler_wait_leaves_through_the_core
    assert_equal 1, exit_calls(File.read(File.join(ROOT, 'otp/erts/emulator/beam/erl_process.c')))
  end

  def test_the_source_check_catches_a_wait_that_takes_nothing_as_it_leaves
    assert_equal 0, exit_calls("scheduler_wait(int *fcalls, ErtsSchedulerData *esdp, ErtsRunQueue *rq)\n{\n" \
                               "    while (1) { break; }\n    erts_runq_lock(rq);\n    sched_active(esdp->no, rq);\n}\n")
  end

  private

  # Calls of the exit in what scheduler_wait does last: after the last block closed at the
  # function's own indent, which puts thread progress back to active as a delivery needs, and
  # before it takes the run queue's lock again.
  def exit_calls(source)
    body = source[/^scheduler_wait\(int \*fcalls.*?^}$/m]
    up_to_relock = body[/.*\berts_runq_lock\(rq\);\s*sched_active\(esdp->no, rq\);/m]
    after_last_block = up_to_relock.rpartition(/^    }$/).last
    after_last_block.scan('erx_event_leave_wait(ssi->park_slot);').size
  end

  def run_harness(*extra)
    Dir.mktmpdir('erx-event-') do |directory|
      binary = File.join(directory, 'harness')
      log, built = Open3.capture2e('clang', *FLAGS, *extra, HARNESS, CORE, '-o', binary, stdin_data: '')
      assert built.success?, log
      Open3.capture2e({ 'TSAN_OPTIONS' => 'halt_on_error=1' }, 'gtimeout', '-k', '5', BUDGET_SECONDS, binary, stdin_data: '')
    end
  end
end
