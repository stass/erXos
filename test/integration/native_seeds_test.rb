# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_irq'
require_relative '../../tools/lib/erx/native_semaphore_race'
require_relative '../../tools/lib/erx/native_threads'
require_relative '../../tools/lib/erx/native_task'
require_relative '../../tools/lib/erx/native_watchdog'
require_relative '../fixtures/generated_tree'

# The threads, watchdog, task and interrupt suites' seeded failures (docs/design-stopgap.md,
# "Verification"): each seed breaks one thing in a copy of the sources, and the suite's
# run under TCG must say so, naming the case. A seed that makes no difference means its
# case does not run the code it claims to. Each boots QEMU and those that lose a wake
# wait out the guest's patience, so `make check` excuses this file
# (STANDALONE_INTEGRATION_TESTS in tools/erx) and `make check-native-seeds` runs it.
# Needs ERX_CLANG, ERX_LLD and a built kernel; a missing tool is a failure, not a skip.
class NativeSeedsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # What the seeded suites compile, at the same paths as in the tree: the interrupt
  # root takes erx_device's C from ERTS's NIF directory, and every program the
  # generated tree's sources and headers.
  COPIED = %w[include kernel liberx test otp/erts/emulator/nifs/erxos build/gen].freeze
  THREAD = 'liberx/backend/fiasco/thread.c'
  SERVICE = 'liberx/backend/fiasco/service.c'
  WATCHDOG = 'liberx/backend/fiasco/watchdog_thread.c'
  TASK = 'liberx/backend/fiasco/service_task.c'
  PARK = 'liberx/backend/core/park_table.c'
  IRQ = 'liberx/backend/fiasco/irq.c'
  DISPATCHER = 'liberx/backend/fiasco/park.c'
  IRQ_GUEST = 'test/guest/native_irq/guest.c'
  ACK_BODY = "\tif (status == ERX_OK && object->made)\n\t\t(void)l4_irq_unmask(irq_cap(object));\n"
  REAP_CALL = "\tif (erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_REAP, &request, sizeof(request), &reply) != ERX_OK)\n" \
              "\t\treaper_refused(\"erx: reaper: the service refused a deletion\\n\");\n"
  CLEAR = "\tif (record->clear_word != 0) {\n" \
          "\t\tatomic_store_explicit((_Atomic uint32_t *)(uintptr_t)record->clear_word, 0, memory_order_release);\n" \
          "\t\t(void)erx_umtx_wake(record->clear_word, 1);\n" \
          "\t}\n"
  Seed = Data.define(:file, :from, :to, :suite, :cpus, :expected)
  SEEDS = {
    'the clear before the deletion' => Seed.new(file: THREAD, from: REAP_CALL + "\tif (record->release_size", to: "#{CLEAR}#{REAP_CALL}\tif (record->release_size",
                                                suite: :threads, cpus: 4, expected: /join_loop FAILED/),
    'the clear removed' => Seed.new(file: THREAD, from: CLEAR, to: '', suite: :threads, cpus: 1, expected: /join_loop FAILED/),
    'the range not released' => Seed.new(file: THREAD, from: "record->release_size = size;\n", to: "record->release_size = 0;\n\t(void)size;\n",
                                         suite: :threads, cpus: 1, expected: /detached_loop FAILED/),
    'the mask ignored' => Seed.new(file: SERVICE, from: "param.affinity = l4_sched_cpu_set(0, 0, mask);\n\treturn (param);", to: "(void)mask;\n\treturn (param);",
                                   suite: :threads, cpus: 4, expected: /affinity_each_cpu FAILED/),
    'the epoch comparison removed' => Seed.new(file: PARK, from: "if (park->group_epoch != event->group_seen || park->slot_epoch[slot] != event->slot_seen)\n\t\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_RETURN });\n", to: '',
                                               suite: :threads, cpus: 1, expected: /park_alone FAILED/),
    'the trampoline omits the thread pointer' => Seed.new(file: 'liberx/backend/fiasco/arch/aarch64/thread_start.S', from: "\tmsr\ttpidr_el0, x11\n", to: '',
                                                          suite: :threads, cpus: 1, expected: /tls_and_arg FAILED/),
    'the failed start deletes nothing' => Seed.new(file: SERVICE, from: "\tif (!service_thread_steps(task, index, ip)) {\n\t\tservice_thread_delete(task, index);\n", to: "\tif (!service_thread_steps(task, index, ip)) {\n",
                                                   suite: :threads, cpus: 1, expected: /failed_start FAILED/),
    'the watchdog never ends the machine' => Seed.new(file: WATCHDOG, from: "\t\tif (step.action == ERX_WATCHDOG_END)\n\t\t\terx_fiasco_end_watchdog(&step.end);\n", to: '',
                                                      suite: :watchdog, cpus: 1, expected: /UNCAUGHT/),
    'the read-write alias mapped read-execute' => Seed.new(file: 'liberx/backend/core/vm_table.c', from: 'addr + done, prot);', to: 'addr + done, ERX_PROT_RX);',
                                                           suite: :task, cpus: 1, expected: /service FAILED/),
    'the thread deletion skipped' => Seed.new(file: TASK, from: "\t\t\ttask_delete(erx_fiasco_task_thread_cap(task, index));\n", to: "\t\t\tcontinue;\n",
                                              suite: :task, cpus: 1, expected: /service FAILED/),
    # The create path's error exit closes the range table too, so the seed anchors on the teardown's pair.
    'the memory step skipped' => Seed.new(file: TASK, from: "\terx_fiasco_gate_task_gone(task);\n\terx_fiasco_vm_task_close(task);\n",
                                          to: "\terx_fiasco_gate_task_gone(task);\n",
                                          suite: :task, cpus: 1, expected: /service FAILED/),
    'the pets ignored' => Seed.new(file: WATCHDOG, from: "\t\tif (pet != last_pet) {", to: "\t\tif (false && pet != last_pet) {",
                                   suite: :watchdog, cpus: 1, expected: /exited before completing its transcript/),
    'the ack removed' => Seed.new(file: IRQ, from: ACK_BODY, to: '',
                                  suite: :irq, cpus: 1, expected: /a lost wake/),
    'the listed flag ignored' => Seed.new(file: PARK, from: 'if ((park->listed & (UINT64_C(1) << event->object)) == 0) {', to: '{',
                                          suite: :irq, cpus: 1, expected: /status page's ready disagrees/),
    'the interlock removed' => Seed.new(file: PARK, from: "if (park->group_epoch != event->group_seen || park->slot_epoch[slot] != event->slot_seen)\n\t\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_RETURN });\n", to: '',
                                        suite: :irq, cpus: 1, expected: /a trigger before the park was lost/),
    'the dispatcher triggers nothing' => Seed.new(file: DISPATCHER, from: "\t\terx_fiasco_group_signal((uint32_t)record);\n", to: "\t\tcontinue;\n",
                                                  suite: :irq, cpus: 1, expected: /a lost wake/),
    'the hook before the park removed' => Seed.new(file: IRQ_GUEST, from: "\ttrigger_and_see(irq_soft);\n\tif (erx_park(group, slot,", to: "\tif (erx_park(group, slot,",
                                                   suite: :irq, cpus: 1, expected: /a trigger before the park was lost/),
    'a task binds into a group it does not home' => Seed.new(file: IRQ, from: "\tif (!irq_group_allowed(task, group) || (object->group", to: "\tif ((object->group",
                                                             suite: :irq, cpus: 1, expected: /the holder's status 30 FAILED/),
    'a task makes an IRQ object' => Seed.new(file: IRQ, from: "\tif (task != ERX_FIASCO_TASK_ROOT || request->kind == ERX_IRQ_MSI)\n", to: "\tif (request->kind == ERX_IRQ_MSI)\n",
                                             suite: :task, cpus: 1, expected: /irq_refused FAILED/)
  }.freeze

  def run_suite(source, seed)
    case seed.suite
    when :threads then Erx::NativeThreads::Run.new(root: ROOT, source: source).call(accels: %w[hvf], cpus: [seed.cpus], build: false)
    when :task then Erx::NativeTask::Run.new(root: ROOT, source: source).call(accels: %w[hvf], cpus: [seed.cpus], build: false)
    when :watchdog then Erx::NativeWatchdog::Run.new(root: ROOT, source: source).call(accels: %w[hvf], cpus: [seed.cpus], build: false)
    when :irq then Erx::NativeIrq::Run.new(root: ROOT, source: source).call(accels: %w[hvf], cpus: [seed.cpus], build: false)
    end
  end

  # A seed of its own kind: a second kernel build holds its up open
  # while a down's timeout races it. Only this suite boots that kernel, which is why the
  # QEMU gate's roster leaves it to this target. It builds first: building the test kernel
  # on inputs newer than the last build deletes what the other seeds link against.
  def test_an_up_held_across_a_timed_down
    ran = Erx::NativeSemaphoreRace::Run.new(root: ROOT).call(accels: %w[hvf], cpus: [4], build: true)
    assert_equal %w[hvf-4cpu], ran.keys
  end

  SEEDS.each do |name, seed|
    define_method("test_#{name.tr(' ', '_')}") do
      Dir.mktmpdir('erx-native-seed-') do |directory|
        COPIED.each do |entry|
          parent = File.join(directory, File.dirname(entry))
          FileUtils.mkdir_p(parent)
          FileUtils.cp_r(File.join(ROOT, entry), parent)
        end
        path = File.join(directory, seed.file)
        text = File.read(path)
        assert_equal 1, text.scan(seed.from).size, 'the seed no longer applies to exactly one place'
        File.write(path, text.sub(seed.from) { seed.to })
        error = assert_raises(Erx::Error) { run_suite(directory, seed) }
        assert_match seed.expected, error.message
      end
    end
  end
end
