# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The gate worker's core (otp/erts/emulator/sys/erxos/erx_gate_core.c) through its host
# driver, test/fixtures/erx_gate_core_driver.c, under the address and undefined sanitizers:
# a record for a label no sink holds is counted and dropped, a sink's records are kept in
# order and its slot refills after a take, a full slot drops and counts the newest, a removed sink's
# records go with it, and an add is refused without an IRQ object, for a label held, and
# with the table full. Seeded failures of the core must each fail their case.
class ErxGateCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'otp/erts/emulator/sys/erxos/erx_gate_core.c'
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  CASES = %w[unknown-label second-record-in-order slot-refills full-slot remove add-refusals].freeze

  def test_every_case_passes
    results = run_driver(build(File.join(ROOT, CORE)))
    assert_equal CASES, results.keys
    assert_equal [], failed(results), results.values.join("\n")
  end

  # A seeded failure of the core, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'a record for an unregistered label reaches a sink' =>
      ['unknown-label', 'if (sink->irq != ERX_CAP_NULL && sink->label == label)',
       'if (sink->irq != ERX_CAP_NULL && (sink->label == label || index == 0))'],
    'a deposit overwrites an undelivered record' =>
      ['second-record-in-order', 'sink->records[sink->count++] = *record;',
       'sink->records[0] = *record;
	sink->count++;']
  }.freeze

  def test_seeded_failures_are_caught
    source = File.read(File.join(ROOT, CORE))
    Dir.mktmpdir('erx-gate-core-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
        path = File.join(directory, "#{name.tr(' ', '-')}.c")
        File.write(path, source.sub(original, replacement))
        assert_includes failed(run_driver(build(path))), expected, "seeded failure not caught by its case: #{name}"
      end
    end
  end

  private

  def failed(results) = results.reject { |_, line| line.end_with?(' ok') }.keys

  def build(source)
    @directory ||= Dir.mktmpdir('erx-gate-core-')
    binary = File.join(@directory, File.basename(source, '.c'))
    output, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT),
                                     '-I', File.join(ROOT, 'include'),
                                     '-I', File.join(ROOT, 'otp/erts/emulator/sys/erxos'),
                                     File.join(ROOT, 'test/fixtures/erx_gate_core_driver.c'), source,
                                     '-o', binary, stdin_data: '')
    assert status.success?, output
    binary
  end

  # Each case's name and its line. A failed case exits 1; anything else, a sanitizer's
  # report included, is a broken run.
  def run_driver(binary)
    output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    assert [0, 1].include?(status.exitstatus), output
    lines = output.lines(chomp: true).grep(/\Acase /)
    assert_equal lines.size, output.lines.size, output
    lines.to_h { |line| [line.split[1], line] }
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && passed? && File.directory?(@directory)
  end
end
