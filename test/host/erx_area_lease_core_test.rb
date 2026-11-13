# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# The lease's core (otp/erts/emulator/nifs/erxos/erx_area_lease_core.c) through its host
# driver, test/fixtures/erx_area_lease_core_driver.c, under the address and undefined
# sanitizers: every order of takes, give-backs, the holder's exit and the driver's return
# keeps a lease taken at most once, only by its holder's port, and returned exactly once
# (docs/design-display.md, Verification, the lease's transitions), and erx_area:lend/5's
# range check refuses every range the design lists. Seeded failures of the core must each
# fail their case.
class ErxAreaLeaseCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  CORE = 'otp/erts/emulator/nifs/erxos/erx_area_lease_core.c'
  DRIVER = 'test/fixtures/erx_area_lease_core_driver.c'
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  CASES = %w[transitions range].freeze

  def test_every_case_passes
    results = run_driver(build(File.join(ROOT, CORE)))
    assert_equal CASES, results.keys
    assert_equal [], failed(results), results.values.join("\n")
  end

  # A seeded failure of the core, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    "the holder's exit returns a taken lease" =>
      ['transitions', 'if (event == ERX_LEASE_DRIVER_RETURN)',
       'if (event == ERX_LEASE_DRIVER_RETURN || event == ERX_LEASE_HOLDER_EXIT)'],
    'a returned lease is returned again' =>
      ['transitions', "case ERX_LEASE_RETURNED:\n\t\treturn (stay);",
       "case ERX_LEASE_RETURNED:\n\t\tif (event == ERX_LEASE_HOLDER_EXIT)\n\t\t\t" \
       "return ((erx_lease_step_t){ .next = state, .taken = false, .returned = true });\n\t\treturn (stay);"],
    'a take ignores the owner' =>
      ['transitions', 'if (event == ERX_LEASE_TAKE && eligible)', 'if (event == ERX_LEASE_TAKE && (eligible || state == ERX_LEASE_HELD))'],
    'the range check has no bound' =>
      ['range', 'return (end <= area_bytes);', 'return (end - bytes <= area_bytes);']
  }.freeze

  def test_seeded_failures_are_caught
    source = File.read(File.join(ROOT, CORE))
    Dir.mktmpdir('erx-area-lease-core-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
        path = File.join(directory, "#{name.tr(" '", '--')}.c")
        File.write(path, source.sub(original, replacement))
        assert_includes failed(run_driver(build(path))), expected, "seeded failure not caught by its case: #{name}"
      end
    end
  end

  private

  def failed(results) = results.reject { |_, line| line.end_with?(' ok') }.keys

  def build(source)
    binary = "#{source.delete_suffix('.c')}-driver"
    binary = File.join(Dir.mktmpdir('erx-area-lease-core-'), 'driver') if source.start_with?(ROOT)
    output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', File.join(ROOT, 'otp/erts/emulator/nifs/erxos'),
                                     '-I', File.join(ROOT, 'build/gen/include'), '-I', File.join(ROOT, 'include'),
                                     source, File.join(ROOT, DRIVER), '-o', binary, stdin_data: '')
    assert status.success?, output
    binary
  end

  def run_driver(binary)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', binary, stdin_data: '')
    assert status.success?, output
    output.lines.map(&:chomp).to_h { |line| [line.split.first, line] }
  end
end
