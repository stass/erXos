# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/native_memory'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# The Fiasco backend's page pool and the backends' range table, on the host: the driver
# test/fixtures/fiasco_vm_driver.c runs them exhaustively against a fake memory
# unit and a table of what each page should be. Each mutant below seeds a failure
# the design names, or the bug it would be, and the driver must catch it, which
# shows the driver reaches that code. liberx/backend/fiasco/page_pool.c and
# liberx/backend/core/vm_table.c are the cores under test.
class FiascoVmTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORES = %w[liberx/backend/fiasco/page_pool.c liberx/backend/core/vm_table.c liberx/backend/core/grow_table.c].freeze
  DRIVER = 'test/fixtures/fiasco_vm_driver.c'

  # Each edits exactly one place in its core, and the driver must name what is
  # wrong: name => [core, original, replacement, the driver's diagnostic].
  MUTANTS = {
    'a contiguous run past the first fit' => ['page_pool.c', 'if (free_run < pages)', 'if (free_run <= pages)', 'contig: first fit'],
    'a contiguous run over a held page' => ['page_pool.c', 'contig_held(pool, last) ? 0 : free_run + 1;', 'contig_held(pool, last) ? free_run + 1 : free_run + 1;', 'contig: first fit'],
    'a contiguous run past the limit' => ['page_pool.c', 'limit < pool->pages ? limit : pool->pages;', '((void)limit, pool->pages);', %q(contig: a limit below every page)],
    'a contiguous run past the pool' => ['page_pool.c', 'limit < pool->pages ? limit : pool->pages;', 'limit < ERX_FIASCO_CONTIG_PAGES ? limit : ERX_FIASCO_CONTIG_PAGES;', %q(contig: a run past a small pool's end)],
    'a contiguous run past the window end' => ['page_pool.c', '(span + 1) / ERX_PAGE_SIZE;', 'span / ERX_PAGE_SIZE + 1;', 'contig: the pages inside a window'],
    'a contiguous run below the window start' => ['page_pool.c', 'if (first > physical || last < physical)', 'if (first > last || last < physical)', 'contig: the pages inside a window'],
    'write with execute admitted' => ['vm_table.c', "\t\tdefault:\n\t\t\treturn (ERX_EINVAL);", "\t\tdefault:\n\t\t\tplan->target = ERX_BACKEND_PAGE_RX;\n\t\t\tbreak;", 'a protection that is not one passed'],
    'zeroing skipped' => ['page_pool.c', "\tbzero((void *)page, ERX_PAGE_SIZE);\n", '', 'a taken page is not zero'],
    'a take not counted' => ['page_pool.c', "\tpool->held_pages++;\n", '', 'a take did not count the page as held'],
    'a put not counted' => ['page_pool.c', "\t\tpool->held_pages--;\n", "\t\t;\n", 'a put did not take the page off the held count'],
    'the count wraps' => ['page_pool.c', "\tif (pool->held_pages > 0)\n", '', 'the held count wrapped'],
    'protect takes a fresh page' => ['vm_table.c', "\tif (steps.take)\n", "\tif (steps.take || steps.map != ERX_PROT_NONE)\n", 'a page lost its contents'],
    'wrong window page' => ['vm_table.c', 'effects->map(table->label, window, addr, steps.map);', 'effects->map(table->label, steps.take ? window : window + ERX_PAGE_SIZE, addr, steps.map);', 'a page lost its contents'],
    'pool check removed' => ['vm_table.c', "\tif (plan.pages_needed > effects->free_pages())\n\t\treturn (ERX_ENOMEM);\n", '', "the call's result differs"],
    'plan applied page by page' => ['vm_table.c', "\tif (plan.pages_needed > effects->free_pages())\n\t\treturn (ERX_ENOMEM);\n", "\tif (plan.pages_needed > effects->free_pages()) {\n\t\tplan.end = plan.start + ERX_PAGE_SIZE;\n\t\tapply_plan(table, effects, &plan);\n\t\treturn (ERX_ENOMEM);\n\t}\n", 'a refused call changed something'],
    'commit on access change removed' => ['vm_table.c', '[ERX_BACKEND_PAGE_RW] = { .take = true, .map = ERX_PROT_RW, .after = ERX_BACKEND_PAGE_RW }', '[ERX_BACKEND_PAGE_RW] = { .after = ERX_BACKEND_PAGE_UNCOMMITTED }', 'a page has the wrong rights'],
    'the drop step skipped' => ['vm_table.c', '.drop = VM_RIGHT_W, .map = ERX_PROT_RX,', '.map = ERX_PROT_RX,', 'a page writable and executable at once'],
    'a raise without its map' => ['vm_table.c', '[ERX_BACKEND_PAGE_R] = { .map = ERX_PROT_R, .after = ERX_BACKEND_PAGE_R }', '[ERX_BACKEND_PAGE_R] = { .after = ERX_BACKEND_PAGE_R }', 'a page has the wrong rights'],
    'page given back still mapped' => ['vm_table.c', "[ERX_BACKEND_PAGE_RX] = {\n\t\t[ERX_BACKEND_PAGE_UNCOMMITTED] = { .drop = VM_RIGHTS_ALL, .give_back = true,", "[ERX_BACKEND_PAGE_RX] = {\n\t\t[ERX_BACKEND_PAGE_UNCOMMITTED] = { .give_back = true,", 'a page has the wrong rights'],
    'probe run left with a hole' => ['vm_table.c', "\t\t\ttable->pages[hole] = table->pages[next];\n\t\t\thole = next;\n", '', 'a page has the wrong rights'],
    'adjacent runs do not merge' => ['vm_table.c', 'const bool joins_before = after > 0 && run_at(table, after - 1)->end == start;', 'const bool joins_before = false;', 'a fixed reserve inside a run changed the count'],
    'reserve keeps the runs it replaces' => ['vm_table.c', "\t\tranges_remove(table, plan->start, plan->end);\n", "\t\tif (plan->op == ERX_BACKEND_VM_RELEASE)\n\t\t\tranges_remove(table, plan->start, plan->end);\n", 'a fixed reserve inside a run changed the count'],
    'reserve keeps the pages it replaces' => ['vm_table.c', "\tpages_move(table, effects, plan->start, plan->end, plan->target);\n", "\tif (plan->op != ERX_BACKEND_VM_RESERVE)\n\t\tpages_move(table, effects, plan->start, plan->end, plan->target);\n", "the pool's count does not add up"],
    'a splitting release takes no room' => ['vm_table.c', "\tif (request->op == ERX_BACKEND_VM_RELEASE && ranges_split(table, plan->start, end)) {\n", "\tif (false) {\n", "a run written outside the table's room"],
    'a reserve takes no room' => ['vm_table.c', "\treturn (plan_one_more_run(table, plan));\n", "\treturn (0);\n", "a run written outside the table's room"],
    'a refused room ignored' => ['vm_table.c', "\terror = erx_backend_grow_table_room(&table->runs, plan.runs_room);\n\tif (error != 0)\n\t\treturn (error);\n", "\t(void)erx_backend_grow_table_room(&table->runs, plan.runs_room);\n", 'a reserve passed with the table full'],
    'the overlap check removed' => ['vm_table.c', ' || mappings_meet(table, addr, end))', ')', 'an alias writable and executable at once'],
    'the release decrement removed' => ['vm_table.c', "\t\teffects->unmapped(gone.object);\n", '', 'a release over a mapping left it'],
    'a release that cuts a mapping admitted' => ['vm_table.c', "\tif (request->op == ERX_BACKEND_VM_RELEASE && mappings_cut(table, plan->start, end))\n\t\treturn (ERX_EINVAL);\n", '', 'a call against a mapping answered wrong'],
    'a commit over a mapping admitted' => ['vm_table.c', "(request->op == ERX_BACKEND_VM_COMMIT || request->op == ERX_BACKEND_VM_DECOMMIT) &&", "request->op == ERX_BACKEND_VM_DECOMMIT &&", 'a call against a mapping answered wrong'],
    'the index ignores the label' => ['vm_table.c', "\treturn (addr | table->label);\n", "\t(void)table;\n\treturn (addr);\n", 'two tables share a page'],
    'an alias over a committed page admitted' => ['vm_table.c', 'count_takes(table, addr, end, ERX_BACKEND_PAGE_RW) != size / ERX_PAGE_SIZE || mappings_meet', 'mappings_meet', 'an alias over a committed page passed'],
    'an alias of addresses not reserved admitted' => ['vm_table.c', "\tif (!range_reserved(table, addr, end) || __builtin_add_overflow(object->area_start, offset, &first))\n", "\tif (__builtin_add_overflow(object->area_start, offset, &first))\n", 'a bad alias passed'],
    'clearing leaves the pages' => ['vm_table.c', "\t\tapply_plan(table, effects, &plan);\n\t}\n\terx_backend_grow_table_clear", "\t\t(void)plan;\n\t\t(void)effects;\n\t\ttable->nranges--;\n\t}\n\terx_backend_grow_table_clear", 'clearing one table reached'],
    'a free range too small accepted' => ['vm_table.c', 'if (gap <= range->start && range->start - gap >= size) {', 'if (gap <= range->start && range->start - gap > 0) {', 'a non-fixed reserve landed wrong'],
  }.freeze
  MEMORY_ERRORS = ['a splitting release takes no room', 'a reserve takes no room'].freeze

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

  # The root sizes its contiguous pool by erx_fiasco_contig_order and the packer counts
  # it by Manifest::RootStartup.contiguous_pool_bytes; the two agree on every total the
  # driver prints, and both refuse what no pool holds.
  def test_the_pool_order_agrees_with_the_packer
    output = run_driver(build(CORES.map { |core| File.join(ROOT, core) }, name: 'driver'))
    pools = output.scan(/^contig pool (\d+) (\d+)$/).map { |pair| pair.map { |value| Integer(value) } }
    assert_equal 12, pools.size, output
    pools.each do |total, pool|
      expected = total > Erx::Manifest::RootStartup::CONTIGUOUS_POOL_MAX_BYTES ? 0 : Erx::Manifest::RootStartup.contiguous_pool_bytes(total)
      assert_equal expected, pool, total
    end
  end

  def test_the_cores_agree_with_both_models
    output = run_driver(build(CORES.map { |core| File.join(ROOT, core) }, name: 'driver'))
    assert_match(/^exhaustive: [1-9][0-9]* calls$/, output)
    assert_match(/^random: seed [0-9]+, 20000 calls$/, output)
    assert_match(/^ok: [1-9][0-9]* checks$/, output)
  end

  MUTANTS.each do |name, (core, original, replacement, diagnostic)|
    define_method("test_the_driver_catches_#{name.tr(' ', '_')}") do
      assert_named driver_failure(mutant(name, core, original, replacement)), name, diagnostic
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

  # Under a sanitizer, a mutant whose bug is a memory error is named first by the
  # sanitizer's report, which counts as the driver naming it.
  SANITIZER_REPORT = /AddressSanitizer|runtime error:/

  def assert_named(output, name, diagnostic)
    return if !@sanitizer_flags.empty? && MEMORY_ERRORS.include?(name) && output.match?(SANITIZER_REPORT)

    assert_includes output, diagnostic
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(cores, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE',
                 *@sanitizer_flags, *Erx::Generated.include_flags(root: ROOT),
                 '-I', File.join(ROOT, 'include'), '-I', ROOT, *cores,
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
    source = File.read(File.join(ROOT, CORES.find { |path_in_tree| File.basename(path_in_tree) == core }))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
    path = File.join(@directory, "#{name.tr(' ', '-')}-#{core}")
    File.write(path, source.sub(original) { replacement })
    others = CORES.reject { |path_in_tree| File.basename(path_in_tree) == core }.map { |other| File.join(ROOT, other) }
    build([path, *others], name: "mutant-#{name}")
  end
end
