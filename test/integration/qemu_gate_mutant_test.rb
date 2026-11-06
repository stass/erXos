# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/debug_log_probe'
require_relative '../../tools/lib/erx/qemu_gate'

# Proves the QEMU gate fails when a call's result on the target breaks. The
# probe guest is built from a copy of the sources in which the Fiasco backend's
# native call asks for one byte more than a full message holds, so the guest
# on QEMU answers differently while the hosted backend, which does not use that
# code, still agrees with the expected transcript. A control run of an
# unmutated copy must pass, so the failure is the mutation's.
#
# Needs ERX_CLANG and ERX_LLD (the run builds the kernel), and boots QEMU under TCG, so
# `make check` excuses it (STANDALONE_INTEGRATION_TESTS in tools/erx) and
# `make check-qemu-mutant` runs it. A missing tool is a failure, not a skip.
class QemuGateMutantTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  STUB = 'liberx/backend/fiasco/log.c'
  CALL = '{ (uint64_t)len.raw };'
  MUTANT = '{ (uint64_t)len.raw + (len.raw == 504) };'
  COPIED = %w[include kernel liberx test].freeze

  def source_copy(directory, mutate:)
    COPIED.each { |entry| FileUtils.cp_r(File.join(ROOT, entry), directory) }
    return unless mutate

    path = File.join(directory, STUB)
    text = File.read(path)
    assert_includes text, CALL, 'the native call changed shape; update the mutation'
    File.write(path, text.sub(CALL, MUTANT))
  end

  def gate_status(source)
    probe = lambda do |_context|
      runs = Erx::DebugLogProbe::Run.new(root: ROOT, source: source).call(accels: %w[hvf], cpus: [1])
      Erx::QemuGate.result(runs.transform_values { 'passed' })
    end
    context = Erx::QemuGate::Context.new(root: ROOT, jobs: 8)
    suite = Erx::QemuGate::Suite.new(name: 'debug_log', cells: %w[hvf-1cpu], run: probe)
    results = Erx::QemuGate.run(suites: [suite], context: context)
    [Erx::QemuGate.status(results.fetch('debug_log')), results.fetch('debug_log').notes]
  end

  def test_the_unmutated_copy_passes
    Dir.mktmpdir('erx-gate-control-') do |directory|
      source_copy(directory, mutate: false)
      assert_equal ['passed', []], gate_status(directory)
    end
  end

  def test_a_broken_kernel_result_fails_the_gate
    Dir.mktmpdir('erx-gate-mutant-') do |directory|
      source_copy(directory, mutate: true)
      status, notes = gate_status(directory)
      assert_equal 'failed', status
      assert_match(/debug-log probe: hvf-1cpu/, notes.first)
    end
  end
end
