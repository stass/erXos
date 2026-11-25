# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/generated_tree'

# Judges the stop's core, kernel/core/machine_stop.c, and the Fiasco fork's descriptor
# table, kernel/core/kip_ram.c (docs/design-debugger.md, "The stop", "Readable RAM",
# "On Fiasco"), through test/fixtures/machine_stop_driver.c: the stop's machine explored
# over every interleaving for one to four CPUs, the claim and the census clock on their
# own, the design's named boot maps, random maps judged page by page, and every
# descriptor type. Each seeded fault the design names must turn a check's line to FAIL.
class MachineStopTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  STOP = 'kernel/core/machine_stop.c'
  KIP = 'kernel/core/kip_ram.c'
  DRIVER = 'test/fixtures/machine_stop_driver.c'

  # name => [source, original, replacement, the check whose line must fail]
  MUTANTS = {
    'the claim reads its own word as another CPU\'s' =>
      [STOP, "if (observed != erx_machine_stop_word(cpu))\n", "if (observed != 0)\n", 'stop 1 cpus'],
    'the census marks an asked CPU stopped without its slot' =>
      [STOP, "\treturn (ERX_STOP_CPU_STATE_UNANSWERED);\n", "\treturn (ERX_STOP_CPU_STATE_STOPPED);\n", 'stop 2 cpus'],
    'the admission loads the stop word before it sets its bit' =>
      [STOP, "\tERX_STOP_STEP_SET_BIT,\n\tERX_STOP_STEP_FENCE,\n\tERX_STOP_STEP_LOAD_WORD,\n",
       "\tERX_STOP_STEP_LOAD_WORD,\n\tERX_STOP_STEP_SET_BIT,\n\tERX_STOP_STEP_FENCE,\n", 'stop 2 cpus'],
    'the leader parks at its own lock wait' =>
      [STOP, 'if (word == 0 || word == erx_machine_stop_word(cpu))', 'if (word == 0)', 'stop 1 cpus'],
    'the census never runs out' =>
      [STOP, 'return (now_ns < since_ns || now_ns - since_ns >= CENSUS_NS);', 'return ((void)since_ns, (void)now_ns, false);',
       'stop 2 cpus'],
    'the leader asks itself' => [STOP, 'leader.asked = loaded & ~cpu_bit(leader.cpu);', 'leader.asked = loaded;', 'stop 1 cpus'],
    'the subtraction skipped' =>
      [STOP, "\tdefault:\n\t\treturn (RAM_KIND_EXCLUDED);\n", "\tdefault:\n\t\treturn (RAM_KIND_IGNORED);\n",
       'ram an interior exclusion splits its bank, rounded outward'],
    'a 17th range dropped without a refusal' =>
      [STOP, "\t\treturn (ERX_RAM_MAP_TOO_MANY);\n", "\t\treturn (ERX_RAM_MAP_OK);\n", 'ram 17 ranges are refused'],
    'an exclusion rounded inward' =>
      [STOP, "\t\t*end = last / ERX_PAGE_SIZE + 1;\n", "\t\t*end = last / ERX_PAGE_SIZE;\n", 'ram random maps'],
    'a used entry not checked' =>
      [STOP, '&& !map_holds(map, first, end))', '&& false)', 'ram used memory past a bank is refused'],
    'Reserved_mmio read as used' =>
      [KIP, 'KIP_SUB_TYPE(lo) == KIP_RESERVED_KERNEL || KIP_SUB_TYPE(lo) == KIP_RESERVED_HEAP',
       'KIP_SUB_TYPE(lo) != 3', 'kip table'],
    'a virtual descriptor read as RAM' =>
      [KIP, "if ((lo & KIP_VIRTUAL) != 0)\n\t\treturn (ERX_RAM_CLASS_IGNORED);\n", '', 'kip table']
  }.freeze

  # A mutant may leave a parameter or helper unused.
  MUTANT_FLAGS = %w[-Wno-unused-parameter -Wno-unused-function].freeze

  def setup
    @directory = Dir.mktmpdir('erx-machine-stop-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(sources: { STOP => File.join(ROOT, STOP), KIP => File.join(ROOT, KIP) }, name: 'driver', extra: [])
    output = File.join(@directory, name.gsub(/[^A-Za-z0-9]+/, '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2', '-g',
                                  *@flags, *extra, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  *sources.values, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  # The driver's lines as check => "ok" or the failure.
  def run_checks(program)
    output, errors, status = Open3.capture3(program, stdin_data: '')
    assert status.success?, errors
    output.lines.to_h { |line| line.chomp.split(': ', 2) }
  end

  def test_every_check_passes
    failed = run_checks(build).reject { |_, result| result == 'ok' }
    assert_empty failed
  end

  def test_each_seeded_fault_fails_its_check
    MUTANTS.each do |name, (source, original, replacement, check)|
      text = File.read(File.join(ROOT, source))
      assert_equal 1, text.scan(original).size, "the mutant #{name} no longer applies"
      mutant = File.join(@directory, "#{name.gsub(/[^A-Za-z0-9]+/, '-')}.c")
      File.write(mutant, text.sub(original, replacement))
      sources = { STOP => File.join(ROOT, STOP), KIP => File.join(ROOT, KIP) }.merge(source => mutant)
      results = run_checks(build(sources: sources, name: name, extra: MUTANT_FLAGS))
      assert results.key?(check), "the driver printed no line for #{check}"
      refute_equal 'ok', results[check], "the mutant #{name} survived #{check}"
    end
  end
end
