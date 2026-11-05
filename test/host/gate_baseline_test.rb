# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/core_archive'
require_relative '../../tools/lib/erx/qemu_gate'
require_relative '../../tools/lib/erx/sanitizer_tests'

# The gates discover what they run, so a deleted or misnamed file could make
# them quietly run less. These tables are floors under that: everything named
# here must stay in its gate. Adding a test, a rule, a target or a seed touches
# nothing here, and so never conflicts. Only taking something away does, which
# turns a removal into a visible edit of this file. What was added after a
# table's last edit has no floor; `tools/erx gates` lists what each gate runs.
class GateBaselineTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  SANITIZER_TESTS = %w[
    test/host/abi_calls_test.rb test/host/blake3_test.rb test/host/boot_file_test.rb test/host/budget_test.rb
    test/host/cap_test.rb test/host/crypto_test.rb test/host/debug_log_probe_test.rb test/host/dispatch_test.rb
    test/host/elf_plan_test.rb test/host/fiasco_umtx_test.rb test/host/fiasco_vm_test.rb test/host/hosted_function_api_test.rb test/host/lane_test.rb
    test/host/log_test.rb test/host/manifest_reader_test.rb test/host/map_test.rb test/host/pack_test.rb
    test/host/rng_test.rb
    test/host/sched_test.rb test/host/space_test.rb test/host/tlb_plan_test.rb test/host/watchdog_test.rb
    test/integration/sanitizer_gate_test.rb test/integration/structural_pack_test.rb
    test/integration/terminal_tables_test.rb
  ].freeze

  # Each native fuzz target's least seed count and sources.
  FUZZ_TARGETS = {
    'blake3' => { seeds: 10, sources: %w[kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c] },
    'boot' => { seeds: 6, sources: %w[kernel/core/pack.c kernel/crypto/blake3/blake3.c
                                           kernel/crypto/blake3/blake3_portable.c] },
    'cap' => { seeds: 4, sources: %w[kernel/core/cap.c] },
    'chacha20' => { seeds: 16, sources: %w[kernel/crypto/chacha20/chacha.c] },
    'dispatch' => { seeds: 8, sources: %w[kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c
                                          kernel/core/log.c kernel/generated/abi_decode.c
                                          kernel/generated/abi_run.c] },
    'elf' => { seeds: 10, sources: %w[liberx/elf_plan.c] },
    'lane' => { seeds: 8, sources: %w[liberx/erx_lane.c] },
    'log' => { seeds: 8, sources: %w[kernel/core/log.c] },
    'ns' => { seeds: 13, sources: %w[liberx/ns.c liberx/release_fs.c] },
    'map' => { seeds: 6, sources: %w[kernel/core/map.c] },
    'pack' => { seeds: 11, sources: %w[kernel/core/pack.c kernel/crypto/blake3/blake3.c
                                            kernel/crypto/blake3/blake3_portable.c] },
    'rng' => { seeds: 6, sources: %w[kernel/core/rng.c kernel/crypto/chacha20/chacha.c kernel/crypto/blake3/blake3.c
                                     kernel/crypto/blake3/blake3_portable.c] },
    'manifest' => { seeds: 11, sources: %w[liberx/generated/abi_reader.c] },
    'sched' => { seeds: 5, sources: %w[kernel/sched/sched.c] },
    'sha256' => { seeds: 8, sources: %w[kernel/crypto/sha2/sha256c.c] },
    'space' => { seeds: 4, sources: %w[kernel/core/space.c kernel/core/cap.c] },
    'watchdog' => { seeds: 11, sources: %w[kernel/core/watchdog.c] }
  }.freeze

  # The include paths every target held.
  FUZZ_INCLUDES = %w[include kernel/core kernel/generated kernel/crypto].freeze

  # Each chokepoint rule's least seed count; a pending or elsewhere rule has
  # no seed, and 0 here.
  RULES = {
    'arch-terms' => 0, 'budget-counters' => 0, 'budget-records-private' => 13, 'cap-slot-clear-callers' => 3,
    'cap-slot-clear-named' => 5, 'cap-slot-private' => 8, 'cap-table-private' => 10, 'core-archive-imports' => 0,
    'core-records-private' => 2, 'dispatch-console-write' => 1, 'dispatch-one-caller' => 1, 'dispatch-one-run' => 2,
    'glue-reads-no-utcb' => 1, 'fiasco-backend-headers-private' => 1, 'fiasco-headers-in-backend' => 2,
    'fiasco-symbols-in-backend' => 2, 'fiasco-vm-body-callers' => 1, 'generated-files' => 0, 'glue-imports' => 0, 'grace-tracker-lock' => 0,
    'include-form' => 1, 'json-input' => 0, 'kernel-stack-proof' => 0, 'lane-pages-reader' => 4,
    'hosted-log-sink' => 2, 'log-format-literal' => 2, 'log-raw-private' => 3, 'map-core-opaque' => 3, 'map-records-private' => 6,
    'object-leg' => 0,
    'one-erx-trap' => 5, 'pmem-converter-sites' => 0, 'raw-allocator-sites' => 0,
    'sched-records-private' => 5, 'seam-only-from-glue' => 1, 'space-holds-callers' => 2, 'space-parent-callers' => 2,
    'space-records-private' => 6, 'vector-route' => 0
  }.freeze

  IMPORTS = %w[fiasco/bootstrap fiasco/drivers-frst fiasco/kernel fiasco/l4re-core fiasco/libfdt fiasco/mk
               kernel/crypto/blake3 kernel/crypto/chacha20 kernel/crypto/sha2 musl otp test/oracle/common_test].freeze

  ARCHIVE_SOURCES = %w[kernel/core/admit.c kernel/core/budget.c kernel/core/cap.c kernel/core/debug_log.c
                       kernel/core/dispatch.c kernel/core/log.c kernel/core/map.c kernel/core/rng.c
                       kernel/core/space.c kernel/core/tlb_plan.c kernel/core/watchdog.c kernel/crypto/blake3/blake3.c
                       kernel/crypto/blake3/blake3_portable.c kernel/crypto/chacha20/chacha.c kernel/crypto/sha2/sha256c.c
                       kernel/generated/abi_decode.c kernel/generated/abi_run.c
                       kernel/sched/sched.c].freeze

  # The suites the QEMU gate runs. The conformance roster's pending cases are
  # not a floor: they come and go as the calls they wait for land.
  QEMU_SUITES = %w[boot_image conformance debug_log native_boot production_image].freeze

  def test_the_qemu_gate_still_runs_every_suite
    assert_empty QEMU_SUITES - Erx::QemuGate.suites.map(&:name)
  end

  def test_the_sanitizer_gate_still_runs_every_test
    assert_empty SANITIZER_TESTS - Erx::SanitizerTests.discover(root: ROOT)
  end

  def test_every_fuzz_target_keeps_its_sources_includes_and_seeds
    targets = Erx::PackFuzz.targets.to_h { |target| [target.kind, target] }
    FUZZ_TARGETS.each do |kind, floor|
      target = targets.fetch(kind) { flunk("fuzz target #{kind} is gone") }
      assert_empty floor.fetch(:sources) - target.sources, "#{kind} lost a source"
      assert_empty FUZZ_INCLUDES - target.includes, "#{kind} lost an include path"
      assert_operator target.seeds.size, :>=, floor.fetch(:seeds), "#{kind} lost seeds"
    end
  end

  def test_every_chokepoint_rule_keeps_its_seeds
    rules = Erx::ChokepointRules::ALL.to_h { |rule| [rule.name, rule] }
    RULES.each do |name, seeds|
      rule = rules.fetch(name) { flunk("chokepoint rule #{name} is gone") }
      assert_operator rule.respond_to?(:seed) ? rule.seed.size : 0, :>=, seeds, "#{name} lost seeds"
    end
  end

  def test_the_imports_and_the_cores_archive_keep_their_members
    assert_empty IMPORTS - Erx::Checks::IMPORTS
    assert_empty ARCHIVE_SOURCES - Erx::CoreArchive.sources(ROOT)
  end
end
