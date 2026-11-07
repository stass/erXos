# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/tlb_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges erx_tlb_plan against TlbModel: random removals from random table
# shapes must leave no stale translation or walk-cache copy once their plan
# is applied, and hand-written removals pin the fallback bound, the
# refusals and the forms of each invalidation.
class TlbPlanTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_TLB_PLAN_SEED', '20261102'))
  PAGE = TlbModel::PAGE
  BY_ADDRESS_MAX = TlbModel::BY_ADDRESS_MAX
  EINVAL = TlbModel::CODEC.constant('einval')
  ASID_LIMIT = 1 << TlbModel::CODEC.constant('arch_asid_bits')
  USER_LIMIT = TlbModel::CODEC.constant('arch_user_limit')
  SHAPES = [[2, 2], [2, 4], [4, 3], [8, 4], [16, 3], [512, 2], [512, 3], [512, 4]].map do |fanout, levels|
    TlbModel::Shape.new(fanout: fanout, levels: levels)
  end.freeze
  # One page at a time, a few small ranges, and ranges wider than any span.
  RANGE_LIMITS = [1, 2, 4, 64, 512, 1 << 21, 1 << 40].freeze
  # A stand-in for an IOMMU's range invalidation, wider than any table span.
  IOMMU_RANGE_LIMIT = 1 << 31

  Entry = Data.define(:kind, :va, :span, :global)
  Request = Data.define(:asid, :range_pages_max, :entries, :null_entries)
  Trial = Data.define(:before, :after, :cleared, :asid, :range_pages_max, :freed)

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-tlb-plan-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported TLB-plan-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build_driver(File.join(@root, 'kernel/core/tlb_plan.c'), name: 'tlb-plan')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_random_removals_leave_nothing_stale
    $stdout.puts("tlb_plan_test: random removals from seed #{SEED} (set ERX_TLB_PLAN_SEED to change it)")
    trials = random_trials(count: 1500, rng: Random.new(SEED))
    plans = plan_all(@driver, trials.map { |trial| request_for(trial) })
    failures = trial_failures(trials, plans)
    assert_empty failures, "seed #{SEED}: #{failures.first(5).join('; ')}"
    assert_random_corpus_reaches_every_case(trials, plans)
  end

  # A DMA window's removal goes through the same planner with its IOMMU's
  # range limit; the IOMMU's binding encodes an every-level invalidation as
  # its non-leaf form. With a limit wider than any span, each cleared table
  # must get exactly one every-level invalidation of its whole span.
  def test_dma_window_removals_get_one_every_level_invalidation_per_cleared_table
    trials = random_trials(count: 400, rng: Random.new(SEED + 1), range_limits: [IOMMU_RANGE_LIMIT])
    plans = plan_all(@driver, trials.map { |trial| request_for(trial) })
    assert_empty trial_failures(trials, plans), "seed #{SEED + 1}"
    trials.zip(plans).each do |trial, plan|
      next if plan.whole_asid?

      trial.cleared.select { |entry| entry.kind == :table }.each do |table|
        inval = plan.invals.find { |candidate| candidate.va == table.va && candidate.pages == table.span / PAGE }
        assert_equal :every, inval&.reach, "table #{table.inspect} needs one every-level invalidation of its span"
      end
    end
  end

  def test_cleared_page_gets_one_last_level_invalidation
    plan = plan_one(request(entries: [page(0x5000)]))
    assert_equal [inval(:last, 0x5000, 1)], plan.invals
  end

  def test_cleared_table_gets_every_level_invalidations_over_its_span
    table = table(0x200000, 8 * PAGE)
    assert_equal (0...8).map { |index| inval(:every, 0x200000 + (index * PAGE), 1) },
                 plan_one(request(range_pages_max: 1, entries: [table])).invals
    assert_equal [inval(:every, 0x200000, 4), inval(:every, 0x204000, 4)],
                 plan_one(request(range_pages_max: 4, entries: [table])).invals
    assert_equal [inval(:every, 0x200000, 8)], plan_one(request(range_pages_max: 1 << 21, entries: [table])).invals
  end

  def test_invalidations_keep_the_order_of_the_cleared_entries
    entries = [page(0x9000), table(0x400000, 2 * PAGE), page(0x1000)]
    assert_equal [inval(:last, 0x9000, 1), inval(:every, 0x400000, 2), inval(:last, 0x1000, 1)],
                 plan_one(request(range_pages_max: 2, entries: entries)).invals
  end

  def test_fallback_to_the_whole_asid_starts_just_past_the_bound
    pages = ->(count) { (0...count).map { |index| page(index * PAGE) } }
    assert_equal BY_ADDRESS_MAX - 1, plan_one(request(entries: pages.call(BY_ADDRESS_MAX - 1))).invals.size
    assert_equal BY_ADDRESS_MAX, plan_one(request(entries: pages.call(BY_ADDRESS_MAX))).invals.size
    assert_equal [inval(:asid, 0, 0)], plan_one(request(entries: pages.call(BY_ADDRESS_MAX + 1))).invals

    at_bound = table(0, BY_ADDRESS_MAX * PAGE)
    assert_equal BY_ADDRESS_MAX, plan_one(request(range_pages_max: 1, entries: [at_bound])).invals.size
    past_bound = table(0, 2 * BY_ADDRESS_MAX * PAGE)
    assert_equal [inval(:asid, 0, 0)], plan_one(request(range_pages_max: 1, entries: [past_bound])).invals
    # A two-page table and 63 pages after it: 2 + 63 = 65 invalidations one
    # page at a time, but 1 + 63 = 64 when one invalidation covers the table.
    mixed = [table(0, 2 * PAGE), *pages.call(BY_ADDRESS_MAX - 1).map { |entry| entry.with(va: entry.va + (4 * PAGE)) }]
    assert_equal [inval(:asid, 0, 0)], plan_one(request(range_pages_max: 1, entries: mixed)).invals
    assert_equal BY_ADDRESS_MAX, plan_one(request(range_pages_max: 2, entries: mixed)).invals.size
  end

  # The AArch64 binding's outcomes at the 4 KiB granule: without range
  # invalidation a last-level table's 512 pages take the whole ASID; with
  # range invalidations of up to 2^21 pages a level-0 entry's 2^27 pages take
  # exactly 64, and one more page tips the plan into the whole ASID.
  def test_aarch64_table_spans_meet_the_bound_as_the_binding_states
    last_level_table = table(0x40000000, 512 * PAGE)
    assert_equal [inval(:asid, 0, 0)], plan_one(request(range_pages_max: 1, entries: [last_level_table])).invals
    level0_entry = table(0, (1 << 27) * PAGE)
    pieces = plan_one(request(range_pages_max: 1 << 21, entries: [level0_entry])).invals
    assert_equal (0...64).map { |index| inval(:every, index * (1 << 21) * PAGE, 1 << 21) }, pieces
    plus_page = [level0_entry, page((1 << 27) * PAGE)]
    assert_equal [inval(:asid, 0, 0)], plan_one(request(range_pages_max: 1 << 21, entries: plus_page)).invals
  end

  def test_fallback_holds_for_many_entries
    entries = (0...50_000).map { |index| page(index * PAGE) }
    assert_equal [inval(:asid, 0, 0)], plan_one(request(entries: entries)).invals
  end

  def test_empty_removal_plans_nothing
    plan = plan_one(request(asid: 0x42, entries: []))
    assert_equal [0, 0x42, []], [plan.status, plan.asid, plan.invals]
    assert_equal 0, plan_one(request(entries: [], null_entries: true)).status
  end

  def test_malformed_removals_are_refused_with_an_empty_plan
    malformed = {
      'global page' => request(entries: [page(0x1000).with(global: true)]),
      'global table' => request(entries: [table(0x200000, 2 * PAGE).with(global: true)]),
      'ASID 0' => request(asid: 0, entries: [page(0x1000)]),
      'ASID past its width' => request(asid: ASID_LIMIT, entries: [page(0x1000)]),
      'no range limit' => request(range_pages_max: 0, entries: [page(0x1000)]),
      'range limit not a power of two' => request(range_pages_max: 3, entries: [page(0x1000)]),
      'unaligned page' => request(entries: [page(0x1800)]),
      'page of two pages' => request(entries: [page(0x2000).with(span: 2 * PAGE)]),
      'table of one page' => request(entries: [table(0x1000, PAGE)]),
      'table span not a power of two' => request(entries: [table(0, 3 * PAGE)]),
      'unaligned table' => request(entries: [table(0x2000, 4 * PAGE)]),
      'page at the user limit' => request(entries: [page(USER_LIMIT)]),
      'table past the user limit' => request(entries: [table(USER_LIMIT, 4 * PAGE)]),
      'table wrapping the address space' => request(entries: [table(2**64 - (2 * PAGE), 2 * PAGE)]),
      'unknown kind' => request(entries: [Entry.new(kind: :bogus, va: 0x1000, span: PAGE, global: false)]),
      'entries behind a null pointer' => request(entries: [page(0x1000)], null_entries: true),
      'one bad entry among good ones' => request(entries: [page(0x1000), page(0x2001), page(0x3000)])
    }
    plans = plan_all(@driver, malformed.values)
    malformed.keys.zip(plans).each do |name, plan|
      assert_equal [EINVAL, 0, []], [plan.status, plan.asid, plan.invals], name
    end
  end

  def test_last_page_below_the_user_limit_and_widest_asid_are_accepted
    plan = plan_one(request(asid: ASID_LIMIT - 1, entries: [page(USER_LIMIT - PAGE)]))
    assert_equal [0, ASID_LIMIT - 1, [inval(:last, USER_LIMIT - PAGE, 1)]], [plan.status, plan.asid, plan.invals]
  end

  # The independent staleness model must catch a planner that leaves
  # walk-cache copies behind, without help from the contract checks. Each
  # mutant edits one line of the planner and must fail it.
  def test_model_catches_planners_that_skip_walk_caches_or_span_coverage
    mutants = {
      'table entries invalidated at the last level only' =>
        ['erx_tlb_add(plan, va, piece_pages, ERX_TLB_EVERY_LEVEL)',
         'erx_tlb_add(plan, va, piece_pages, ERX_TLB_LAST_LEVEL)'],
      'only the first piece of a table span invalidated' =>
        ['for (uint64_t va = entry->va; va < entry->va + entry->span;',
         'for (uint64_t va = entry->va; va < entry->va + piece_bytes;']
    }
    trials = random_trials(count: 400, rng: Random.new(SEED + 2))
    requests = trials.map { |trial| request_for(trial) }
    assert_empty trial_failures(trials, plan_all(@driver, requests), checks: %i[stale]), 'the planner itself'
    mutants.each do |name, (original, replacement)|
      driver = build_driver(mutant_source(name, original, replacement), name: "mutant-#{name.tr(' ', '-')}")
      stale = trial_failures(trials, plan_all(driver, requests), checks: %i[stale])
      refute_empty stale, "the staleness model accepted the mutant: #{name}"
    end
  end

  def test_planner_builds_freestanding_for_the_target
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2',
                 '--target=aarch64-none-elf', '-ffreestanding', '-mgeneral-regs-only',
                 *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-c', File.join(@root, 'kernel/core/tlb_plan.c'),
                 '-o', File.join(@directory, 'tlb_plan.o')], name: 'compile-target', deadline: 60)
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), core,
                 File.join(@root, 'test/fixtures/tlb_plan_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def mutant_source(name, original, replacement)
    source = File.read(File.join(@root, 'kernel/core/tlb_plan.c'))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one line of the planner"
    path = File.join(@directory, "mutant-#{source.hash.abs}-#{name.tr(' ', '-')}.c")
    File.write(path, source.sub(original, replacement))
    path
  end

  def random_trials(count:, rng:, range_limits: RANGE_LIMITS)
    Array.new(count) do
      before = TlbModel.populate(SHAPES.sample(random: rng), rng)
      first, last = TlbModel.removal_range(before, rng)
      removal = TlbModel::Removal.new(before, first: first, last: last, rng: rng)
      after, cleared = removal.call
      Trial.new(before: before, after: after, cleared: cleared, asid: 1 + rng.rand(ASID_LIMIT - 1),
                range_pages_max: range_limits.sample(random: rng), freed: removal.freed)
    end
  end

  # :stale is the independent model; :contract the design's statements.
  def trial_failures(trials, plans, checks: %i[stale contract])
    trials.zip(plans).each_with_index.flat_map do |(trial, plan), index|
      problems = []
      problems += TlbModel.stale_failures(before: trial.before, after: trial.after, plan: plan) if checks.include?(:stale)
      if checks.include?(:contract)
        problems += TlbModel.contract_failures(cleared: trial.cleared, plan: plan, asid: trial.asid,
                                               range_pages_max: trial.range_pages_max)
      end
      problems.map { |problem| "trial #{index} (#{trial.before.shape.to_h}, range #{trial.range_pages_max}): #{problem}" }
    end
  end

  # Guards the generator: for every shape, the random corpus must free a
  # table at every depth below the root both by detaching it whole and by
  # emptying it, and must produce by-address and whole-ASID plans alike.
  def assert_random_corpus_reaches_every_case(trials, plans)
    seen = trials.each_with_object(Set.new) do |trial, set|
      shape = trial.before.shape
      trial.freed.each { |depth, how| set << [shape.fanout, shape.levels, depth, how] }
    end
    expected = SHAPES.flat_map do |shape|
      (1..shape.leaf_depth).flat_map { |depth| %i[detached emptied].map { |how| [shape.fanout, shape.levels, depth, how] } }
    end
    assert_empty expected - seen.to_a, "seed #{SEED}: [fanout, levels, depth, how] never freed"
    assert plans.any?(&:whole_asid?), 'a whole-ASID plan'
    assert plans.any? { |plan| plan.invals.any? { |entry| entry.reach == :every } }, 'an every-level plan'
    assert plans.any? { |plan| plan.invals.any? { |entry| entry.reach == :last } }, 'a last-level plan'
  end

  def request_for(trial)
    entries = trial.cleared.map { |entry| Entry.new(kind: entry.kind, va: entry.va, span: entry.span, global: false) }
    Request.new(asid: trial.asid, range_pages_max: trial.range_pages_max, entries: entries, null_entries: false)
  end

  def request(entries:, asid: 1, range_pages_max: 1, null_entries: false)
    Request.new(asid: asid, range_pages_max: range_pages_max, entries: entries, null_entries: null_entries)
  end

  def page(va) = Entry.new(kind: :page, va: va, span: PAGE, global: false)
  def table(va, span) = Entry.new(kind: :table, va: va, span: span, global: false)
  def inval(reach, va, pages) = TlbModel::Inval.new(reach: reach, va: va, pages: pages)
  def plan_one(request) = plan_all(@driver, [request]).first

  def plan_all(driver, requests)
    input = File.join(@directory, 'removals.txt')
    File.write(input, requests.map { |request| encode(request) }.join)
    record = @runner.run([driver, input], name: 'tlb-plan', deadline: 120)
    plans = decode(File.read(record.fetch('log')))
    assert_equal requests.size, plans.size, 'one plan per removal'
    plans
  end

  def encode(request)
    header = format("%s %x %x %x\n", request.null_entries ? 'null' : 'case', request.asid,
                    request.range_pages_max, request.entries.size)
    return header if request.null_entries

    header + request.entries.map do |entry|
      format("entry %s %x %x %d\n", entry.kind, entry.va, entry.span, entry.global ? 1 : 0)
    end.join
  end

  def decode(output)
    output.lines.slice_before(/\Aplan /).map do |plan_line, *inval_lines|
      _, status, asid, count = plan_line.split
      invals = inval_lines.map do |line|
        _, reach, va, pages = line.split
        inval(reach.to_sym, Integer(va, 16), Integer(pages, 16))
      end
      assert_equal Integer(count), invals.size, 'plan line counts its invalidations'
      TlbModel::Plan.new(status: Integer(status), asid: Integer(asid, 16), invals: invals)
    end
  end
end
