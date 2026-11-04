# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_memory'
require_relative '../../tools/lib/erx/runner'

# The Fiasco backend's page pool and range table, on the host: the driver
# test/fixtures/fiasco_vm_driver.c runs them exhaustively against a fake memory
# unit and a table of what each page should be. Each mutant below seeds a failure
# the design names, or the bug it would be, and the driver must catch it, which
# shows the driver reaches that code. liberx/backend/fiasco/page_pool.c and
# liberx/backend/fiasco/vm_table.c are the cores under test.
class FiascoVmTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORES = %w[liberx/backend/fiasco/page_pool.c liberx/backend/fiasco/vm_table.c].freeze
  DRIVER = 'test/fixtures/fiasco_vm_driver.c'

  # Each edits exactly one place in its core, and the driver must name what is
  # wrong: name => [core, original, replacement, the driver's diagnostic].
  MUTANTS = {
    'write with execute admitted' => ['vm_table.c', "\t\tdefault:\n\t\t\treturn (ERX_EINVAL);", "\t\tdefault:\n\t\t\tplan->target = ERX_FIASCO_PAGE_RX;\n\t\t\tbreak;", 'a protection that is not one passed'],
    'zeroing skipped' => ['page_pool.c', "\tbzero((void *)page, ERX_PAGE_SIZE);\n", '', 'a taken page is not zero'],
    'protect takes a fresh page' => ['vm_table.c', "\tif (steps.take)\n", "\tif (steps.take || steps.map != ERX_PROT_NONE)\n", 'a page lost its contents'],
    'wrong window page' => ['vm_table.c', 'effects->map(window, addr, steps.map);', 'effects->map(steps.take ? window : window + ERX_PAGE_SIZE, addr, steps.map);', 'a page lost its contents'],
    'pool check removed' => ['vm_table.c', "\tif (plan.pages_needed > pool->free_pages)\n\t\treturn (ERX_ENOMEM);\n", '', "the call's result differs"],
    'plan applied page by page' => ['vm_table.c', "\tif (plan.pages_needed > pool->free_pages)\n\t\treturn (ERX_ENOMEM);\n", "\tif (plan.pages_needed > pool->free_pages) {\n\t\tplan.end = plan.start + ERX_PAGE_SIZE;\n\t\tapply_plan(table, pool, effects, &plan);\n\t\treturn (ERX_ENOMEM);\n\t}\n", 'a refused call changed something'],
    'commit on access change removed' => ['vm_table.c', '[ERX_FIASCO_PAGE_RW] = { .take = true, .map = ERX_PROT_RW, .after = ERX_FIASCO_PAGE_RW }', '[ERX_FIASCO_PAGE_RW] = { .after = ERX_FIASCO_PAGE_UNCOMMITTED }', 'a page has the wrong rights'],
    'the drop step skipped' => ['vm_table.c', '.drop = VM_RIGHT_W, .map = ERX_PROT_RX,', '.map = ERX_PROT_RX,', 'a page writable and executable at once'],
    'a raise without its map' => ['vm_table.c', '[ERX_FIASCO_PAGE_R] = { .map = ERX_PROT_R, .after = ERX_FIASCO_PAGE_R }', '[ERX_FIASCO_PAGE_R] = { .after = ERX_FIASCO_PAGE_R }', 'a page has the wrong rights'],
    'page given back still mapped' => ['vm_table.c', "[ERX_FIASCO_PAGE_RX] = {\n\t\t[ERX_FIASCO_PAGE_UNCOMMITTED] = { .drop = VM_RIGHTS_ALL, .give_back = true,", "[ERX_FIASCO_PAGE_RX] = {\n\t\t[ERX_FIASCO_PAGE_UNCOMMITTED] = { .give_back = true,", 'a page has the wrong rights'],
    'probe run left with a hole' => ['vm_table.c', "\t\t\ttable->pages[hole] = table->pages[next];\n\t\t\thole = next;\n", '', 'a page has the wrong rights'],
    'adjacent runs do not merge' => ['vm_table.c', 'const bool joins_before = after > 0 && table->ranges[after - 1].end == start;', 'const bool joins_before = false;', 'a fixed reserve inside a run changed the count'],
    'reserve keeps the runs it replaces' => ['vm_table.c', 'if (plan->op == ERX_FIASCO_VM_RESERVE || plan->op == ERX_FIASCO_VM_RELEASE)', 'if (plan->op == ERX_FIASCO_VM_RELEASE)', 'a fixed reserve inside a run changed the count'],
    'reserve keeps the pages it replaces' => ['vm_table.c', "\tpages_move(table, pool, effects, plan->start, plan->end, plan->target);\n", "\tif (plan->op != ERX_FIASCO_VM_RESERVE)\n\t\tpages_move(table, pool, effects, plan->start, plan->end, plan->target);\n", "the pool's count does not add up"],
    'a splitting release at capacity admitted' => ['vm_table.c', "\tif (request->op == ERX_FIASCO_VM_RELEASE && table->nranges == table->ranges_max &&\n\t    ranges_split(table, plan->start, end))\n\t\treturn (ERX_ENOMEM);\n", '', 'a splitting release passed with the table full'],
    'a reserve at capacity admitted' => ['vm_table.c', "\tif (table->nranges + 1 > table->ranges_max)\n\t\treturn (ERX_ENOMEM);\n", '', 'a reserve passed with the table full'],
    'a free range too small accepted' => ['vm_table.c', 'if (table->ranges[run].start - gap >= size) {', 'if (table->ranges[run].start - gap > 0) {', 'a non-fixed reserve landed wrong']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-vm-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_the_cores_agree_with_both_models
    output = run_driver(build(CORES.map { |core| File.join(ROOT, core) }, name: 'driver'))
    assert_match(/^exhaustive: [1-9][0-9]* calls$/, output)
    assert_match(/^random: seed [0-9]+, 20000 calls$/, output)
    assert_match(/^ok: [1-9][0-9]* checks$/, output)
  end

  MUTANTS.each do |name, (core, original, replacement, diagnostic)|
    define_method("test_the_driver_catches_#{name.tr(' ', '_')}") do
      assert_includes driver_failure(mutant(name, core, original, replacement)), diagnostic
    end
  end

  # What the gate's native_memory suite judges a transcript by, without a guest.
  def test_a_failed_case_fails_at_once_and_names_itself
    verify = Erx::NativeMemory.case_point('refusals').fetch(:verify)
    verify.call("erx: memory: refusals ok\r\n".b)
    error = assert_raises(Erx::Error) { verify.call("erx: memory: refusals FAILED\r\n".b) }
    assert_includes error.message, 'refusals FAILED'
  end

  def test_the_transcript_runs_every_case_between_the_pool_counts
    names = Erx::NativeMemory.checkpoints.map { |point| point.fetch(:name) }
    expected = ['memory-pool-before', *Erx::NativeMemory::CASES.map { |name| "memory-#{name}" }, 'memory-pool-after',
                'memory-pool_count_steady', 'memory-done']
    assert_equal expected, names.last(expected.size)
  end

  def test_a_pool_count_must_be_a_positive_number
    verify = Erx::NativeMemory.pool_point('after').fetch(:verify)
    verify.call("erx: memory: pool after 121164\r\n".b)
    assert_raises(Erx::Error) { verify.call("erx: memory: pool after 0\r\n".b) }
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(cores, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE',
                 *@sanitizer_flags, '-I', File.join(ROOT, 'include'), '-I', ROOT, *cores,
                 File.join(ROOT, DRIVER), '-o', output],
                name: "compile-#{name.tr(' ', '-')}", deadline: 60)
    output
  end

  def run_driver(driver)
    File.read(@runner.run([driver], name: 'run-driver', deadline: 120).fetch('log'))
  end

  # What the driver said as it failed; a driver that passes fails the test.
  def driver_failure(driver)
    output = run_driver(driver)
    flunk("the driver missed this: #{output}")
  rescue Erx::CommandError => e
    File.read(e.result.fetch('log'))
  end

  def mutant(name, core, original, replacement)
    source = File.read(File.join(ROOT, 'liberx/backend/fiasco', core))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
    path = File.join(@directory, "#{name.tr(' ', '-')}-#{core}")
    File.write(path, source.sub(original) { replacement })
    others = CORES.reject { |path_in_tree| File.basename(path_in_tree) == core }.map { |other| File.join(ROOT, other) }
    build([path, *others], name: "mutant-#{name}")
  end
end
