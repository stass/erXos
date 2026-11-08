# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/budget_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the budget core (kernel/core/budget.c) against BudgetModel, which
# recomputes every counter from the tree after each step. The driver runs
# command scripts through the core and prints every status, effect and the
# whole state; the model predicts each line. Bounds: random trees of at
# most 24 budgets and ERX_BUDGET_DEPTH_MAX levels on roots of 64 to 320
# pages, every two-budget tree of the shapes and sizes in
# EXHAUSTIVE_BUDGETS under every operation of EXHAUSTIVE_OPERATIONS, and
# the hand-written cases the design names (K6, K32).
class BudgetTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_BUDGET_SEED', '20261103'))
  M = BudgetModel
  WALL = M::WALL
  ELASTIC = M::ELASTIC
  DEPTH_MAX = M::DEPTH_MAX
  # [kind, guarantee, cap] of one budget of an exhaustive tree.
  EXHAUSTIVE_BUDGETS = [[WALL, 0, 0], [WALL, 2, 2], [WALL, 4, 4], [ELASTIC, 0, 2], [ELASTIC, 0, 6],
                        [ELASTIC, 2, 3], [ELASTIC, 2, 6]].freeze
  # One operation on a tree whose budgets are 1 and 2, with reserves 0 and 1.
  EXHAUSTIVE_OPERATIONS = ['charge 0 1', 'charge 0 2', 'charge 0 4', 'charge 1 1', 'charge 1 2', 'charge 1 4',
                           'resize 1 0 1', 'resize 1 3 6', 'resize 2 1 1', 'resize 2 0 6',
                           'destroy 1', 'destroy 2', 'release 0 0 1', 'release 1 1 0'].freeze
  # One-line edits of the core, each a failure the design says the model
  # must catch.
  MUTANTS = {
    'cap check leaves carved out' => ['step->new_spending > budget->cap)',
                                      'step->new_spending - step->carved > budget->cap)'],
    'close forgets lent' => ["\treturn (difference(0, borrowing(*spent, budget->guarantee),\n\t    &delta->lent));",
                           "\tdelta->lent = 0;\n\treturn (true);"],
    'dead refund stays at the dead budget' => ["if (!difference(step->new_spending, step->old_spending,\n\t\t    &step->up.used))",
                                               'if (0)'],
    'refusal ignores whether spending rises' => ['if (step->new_spending > step->old_spending &&',
                                                 'if (1 &&'],
    'borrowing measured from zero' => ['new_borrowing = borrowing(step->new_spending, budget->guarantee);',
                                       'new_borrowing = borrowing(step->new_spending, 0);'],
    'wall resized off its guarantee' => ["(budget->kind == ERX_BUDGET_WALL && cap != guarantee))\n\t\treturn (ERX_EINVAL);\n\n\terx_effect_budget_lock",
                                         "0)\n\t\treturn (ERX_EINVAL);\n\n\terx_effect_budget_lock"],
    'chain stops one level early' => ["\t\tif (delta_is_zero(&step.up))\n\t\t\tbreak;\n\t\tdelta = step.up;\n\t\tdead_rule",
                                      "\t\tif (delta_is_zero(&step.up) || level->parent == NULL ||\n\t\t    level->parent->parent == NULL)\n\t\t\tbreak;\n\t\tdelta = step.up;\n\t\tdead_rule"],
    'resize never records the new guarantee' => ['budget->guarantee = guarantee;', '(void)0;'],
    'chain planned without its locks' => ["erx_effect_budget_lock(level);\n\t\t(*nlocked)++;",
                                          '(*nlocked)++;'],
    'chain unlocked before it is applied' => ["\tif (error == 0) {\n\t\teffects->refused = NULL;",
                                              "\tchain_unlock(budget, nlocked);\n\tif (error == 0) {\n\t\teffects->refused = NULL;"],
    # K32: every level a refusal reached below the refusing one keeps its
    # change, as if the chain were applied one level at a time.
    'chain applied one level at a time' => ["\tif (error == 0) {\n\t\teffects->refused = NULL;\n\t\tchain_apply(budget, *delta, dead_rule, nlocked, effects);\n\t}",
                                            "\tif (error == 0)\n\t\teffects->refused = NULL;\n\tchain_apply(budget, *delta, dead_rule,\n\t    nlocked - (error != 0 ? 1 : 0), effects);"],
    'cancel refunds nothing' => ["\tdelta.used = -delta.used;\n\terror = chain_change(reserve->budget, &delta,\n\t    BUDGET_DEAD_TAKES_NO_RISE, effects);\n\tif (error == 0)\n\t\treserve->charged -= pages;",
                               "\tdelta.used = 0;\n\terror = chain_change(reserve->budget, &delta,\n\t    BUDGET_DEAD_TAKES_NO_RISE, effects);\n\tif (error == 0)\n\t\treserve->charged -= pages;"]
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-budget-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported budget-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, 'kernel/core/budget.c'), name: 'budget', flags: @sanitizer_flags)
  end

  def test_random_operations_agree_with_the_model
    $stdout.puts("budget_test: random operations from seed #{SEED} (set ERX_BUDGET_SEED to change it)")
    scripts = random_scripts(count: 120, length: 90, rng: Random.new(SEED))
    assert_reaches_every_case(assert_agrees(scripts))
  end

  def test_every_small_tree_agrees_under_every_operation
    scripts = exhaustive_scripts
    assert_operator scripts.size, :>, 4000
    assert_agrees(scripts)
  end

  # K32: a chain ERX_BUDGET_DEPTH_MAX levels deep borrows through every
  # level, refuses a level more, and a nested destroy closes every level
  # before it returns; the tombstones then go one level per round of puts.
  def test_deepest_chain_borrows_through_every_level_and_dies_one_level_per_round
    script = ['root 4096']
    (1...DEPTH_MAX).each { |level| script << "carve #{level - 1} #{ELASTIC} 1 4000" }
    script << "carve #{DEPTH_MAX - 1} #{ELASTIC} 1 4000" << "reserve #{DEPTH_MAX - 1}" << 'charge 0 200'
    script << 'destroy 1'
    script.concat(['put'] * DEPTH_MAX)
    lines = assert_agrees([script])
    results = lines.grep(/\A= /)
    assert_equal M::ELIMIT, status(results.fetch(DEPTH_MAX)), 'a sixteenth level is refused'
    assert_equal 0, status(results.fetch(DEPTH_MAX + 2)), 'the charge borrows through every level'
    freed = results.last(DEPTH_MAX).map { |line| line.scan(/freed=(\d+)/).flatten.map(&:to_i) }
    assert_equal (1...DEPTH_MAX).to_a.reverse.map { |id| [id] } + [[]], freed, 'one level per round'
    assert_match(/\AS free=\d+ rel=\d+ b0:1,0,0,4096,4096,0,0,0,0,0,0\z/, lines.last, 'the root is whole again')
  end

  # K32: a cap set below the spending refuses every rise until the
  # spending falls beneath it, while a child's charge within its own
  # guarantee is admitted; a decrease never fails.
  def test_cap_below_the_spending_refuses_only_rises
    script = ['root 100', "carve 0 #{ELASTIC} 10 60", "carve 1 #{ELASTIC} 5 5", 'reserve 1', 'reserve 2',
              'charge 0 30', 'resize 1 10 20', 'charge 0 1', 'charge 1 4', 'release 0 0 15', 'charge 0 1',
              'release 0 0 10', 'charge 0 1']
    results = assert_agrees([script]).grep(/\A= /)
    assert_equal [M::ENOMEM, 0, 0, M::ENOMEM, 0, 0], results.last(6).map { |line| status(line) }
  end

  # K32: a sibling that borrows takes only the parent's room, never the
  # guarantee the parent made to another child.
  def test_a_siblings_borrowing_never_takes_a_guarantee
    script = ['root 100', "carve 0 #{WALL} 40 40", "carve 1 #{ELASTIC} 10 40", "carve 1 #{ELASTIC} 10 40",
              'reserve 2', 'reserve 3', 'charge 0 29', 'charge 0 1', 'charge 1 10']
    results = assert_agrees([script]).grep(/\A= /)
    assert_equal [0, M::ENOMEM, 0], results.last(3).map { |line| status(line) }
    assert_match(/refused=1\z/, results[-2], 'the wall refuses, not an ancestor')
  end

  # K32: a wall's cap stays equal to its guarantee, and it borrows exactly
  # what a shrink left above the guarantee, falling as its tree frees.
  def test_a_wall_borrows_only_what_a_shrink_left
    script = ['root 100', "carve 0 #{WALL} 30 30", 'reserve 1', 'charge 0 20', 'resize 1 10 20', 'resize 1 10 10',
              'release 0 0 5', 'charge 0 1', 'release 0 0 10', 'charge 0 1']
    lines = assert_agrees([script])
    results = lines.grep(/\A= /)
    assert_equal [M::EINVAL, 0, 0, M::ENOMEM, 0, 0], results.last(6).map { |line| status(line) }
    assert_includes lines.grep(/\AS /)[5], 'b0:1,0,0,100,100,1,10,10,', 'borrowing after the shrink'
    assert_includes lines.last, 'b0:1,0,0,100,100,1,10,0,', 'no borrowing once the spending falls'
  end

  # K6: a backing of 129 pages whose owner closes at each part boundary
  # cancels the unbacked rest; then charged equals backed, and the
  # teardown's release puts every page on the released list exactly once
  # and the budget back at its baseline.
  def test_a_backing_closed_at_every_part_boundary_cancels_the_rest
    (0..2).each do |part|
      script = ['root 300', "carve 0 #{ELASTIC} 10 200", 'reserve 1', "charge 0 129 #{part}"]
      lines = assert_agrees([script])
      assert_equal M::ESTALE, status(lines[-2])
      backed = [129, 64 * part].min
      assert_includes lines.last, " r0:1,#{backed},#{backed},#{backed}"
      final = assert_agrees([script + ["release 0 0 #{backed}"]]).last
      assert_includes final, "rel=#{backed} "
      assert_includes final, 'b1:2,1,0,10,200,0,0,0,0,0,0'
    end
  end

  def test_watch_fires_once_and_rearms
    script = ['root 100', "carve 0 #{ELASTIC} 10 60", 'reserve 1', 'watch 1 3 20', 'charge 0 19', 'charge 0 1',
              'charge 0 5', 'watch 1 3 10', 'watch 1 4 50', 'detach 1 4', 'detach 1 3', 'watch 1 4 50',
              'watch 0 5 0', 'destroy 1', 'watch 1 4 1']
    results = assert_agrees([script]).grep(/\A= /)
    assert_equal ['= 0', '= 0', '= 0 fire=3', '= 0', '= 0 fire=3', "= #{M::EBUSY}", '= 0 detached=0',
                  '= 0 detached=1', '= 0', '= 0 fire=5'], results[3, 10]
    assert_equal M::ESTALE, status(results.last)
  end

  # Pinning raises pinned at every ancestor, dead ones included, and keeps
  # a dead budget's tombstone. In the same plan each level whose pinned
  # rose from zero keeps its record, and the first record kept on a cache
  # page pins the page at the page's budget and above: the first pin of
  # budget 2 pins 1 page at 2, 2 at 1 (2's record page) and 3 at the root
  # (1's too); the second adds one page everywhere.
  def test_pins_count_through_the_tree_and_keep_the_tombstone
    script = ['root 100', "carve 0 #{ELASTIC} 10 60", "carve 1 #{ELASTIC} 5 60", 'reserve 2', 'charge 0 3',
              'pin 2 1', 'pin 2 1', 'pin 1 1', 'destroy 1', 'put', 'put']
    lines = assert_agrees([script])
    results = lines.grep(/\A= /)
    pinned = ->(state) { state.scan(/ b(\d+):(?:[^ ,]+,){8}(\d+)/).to_h { |id, pins| [Integer(id), Integer(pins)] } }
    assert_equal({ 0 => 3, 1 => 2, 2 => 1 }, pinned.call(lines[11]))
    assert_equal({ 0 => 4, 1 => 3, 2 => 2 }, pinned.call(lines[13]))
    assert_equal '= 0', results[5]
    refute_match(/tomb=/, results.last(3).join)
  end

  # A record cache spills onto a second page when the first is full, keeps
  # a page charged while any record on it lives, frees a page once its last
  # record is freed, and two kept records on one page pin it once.
  def test_record_cache_pages_are_charged_while_they_hold_a_record
    children = per_page + 2
    script = ['root 400']
    children.times { script << "carve 0 #{WALL} 1 1" }
    script += ['pin 1 1', 'pin 2 1']
    (3..children).each { |id| script << "destroy #{id}" }
    script += %w[put reap]
    lines = assert_agrees([script])
    cache_pages = ->(state) { Integer(state[/ b0:(?:[^ ,]+,){10}(\d+)/, 1]) }
    assert_equal 2, cache_pages.call(lines[(2 * children) + 1])
    assert_equal 1, cache_pages.call(lines.last), 'the second page goes once its records are freed'
    assert_equal 2 + 1, Integer(lines.last[/ b0:(?:[^ ,]+,){8}(\d+)/, 1]), 'pins 1 and 2 and their one page'
  end

  # The checked arithmetic at the edges of a 64-bit count: each refusal is
  # ERX_EINVAL or ERX_ENOMEM and changes nothing.
  def test_counts_never_wrap
    line = run_script(driver, ['arith']).first
    assert_equal '= 0 root=-1 carve=-1 carve=0 full=-6 min=-1 below=-1 pin=-1 within=0 borrow=-6 unchanged=1 grow=-1',
                 line
  end

  def test_seeded_failures_are_caught
    scripts = random_scripts(count: 40, length: 90, rng: Random.new(SEED + 7)) +
              [deep_borrowing_script, shrink_script, wall_script, closed_backing_script]
    expected = scripts.map { |script| predict(script) }
    MUTANTS.each do |name, (original, replacement)|
      mutant = build_driver(mutant_source(name, original, replacement), name: "mutant-#{name.tr(' ', '-')}",
                                                                       flags: [])
      caught = scripts.zip(expected).any? do |script, lines|
        run_script(mutant, script) != lines
      rescue Erx::Error
        true
      end
      assert caught, "seeded failure not caught: #{name}"
    end
  end

  # The chain's locks under ThreadSanitizer: four threads charge and
  # release at random across a tree while each change takes its chain's
  # locks descendant first; afterwards every counter agrees with the
  # model's recomputation and every page is in exactly one place.
  def test_concurrent_changes_keep_the_accounting_whole
    tsan = build_driver(File.join(@root, 'kernel/core/budget.c'), name: 'budget-tsan',
                                                                 flags: %w[-fsanitize=thread -fno-omit-frame-pointer])
    script = ['root 2000', "carve 0 #{WALL} 600 600", "carve 1 #{ELASTIC} 100 500", "carve 1 #{ELASTIC} 100 500",
              "carve 0 #{ELASTIC} 200 1500", "carve 4 #{ELASTIC} 0 1500", 'reserve 2', 'reserve 3', 'reserve 4',
              'reserve 5', 'reserve 1', 'reserve 0']
    final = run_script(tsan, script + ["race #{SEED} 4000"]).last
    assert_whole(final, pages: 2000)
    recomputed = recompute(final)
    assert_equal recomputed.fetch(:expected), recomputed.fetch(:actual), 'counters after the race'
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  # The driver includes the core's private header by its plain name, as
  # the include-form chokepoint requires, from the core's directory; a
  # mutant core finds its own copy of the header beside it first.
  def build_driver(core, name:, flags:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                 *flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'), core,
                 File.join(@root, 'test/fixtures/budget_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def mutant_source(name, original, replacement)
    source = File.read(File.join(@root, 'kernel/core/budget.c'))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
    directory = File.join(@directory, "source-mutant-#{name.tr(' ', '-')}")
    FileUtils.mkdir_p(directory)
    FileUtils.cp(File.join(@root, 'kernel/core/budget_impl.h'), directory)
    path = File.join(directory, 'budget.c')
    File.write(path, source.sub(original, replacement))
    path
  end

  def run_script(program, script)
    input = File.join(@directory, "script-#{script.hash.abs}.txt")
    File.write(input, script.map { |line| "#{line}\n" }.join)
    record = @runner.run([program, input], name: 'budget-driver', deadline: 300)
    File.read(record.fetch('log')).lines.map(&:chomp).grep(/\A[=SW] /)
  end

  # The records one cache page holds, as the core lays them out: the model
  # places records on pages exactly as the core does.
  def per_page
    @per_page ||= Integer(run_script(driver, ['root 1']).first[/ per=(\d+)/, 1])
  end

  def new_model = BudgetModel.new(per_page: per_page)

  def predict(script)
    model = new_model
    script.flat_map { |line| model.call(line) }
  end

  # Runs every script in one driver process (each starts with root) and
  # compares each line with the model's; returns the driver's lines.
  def assert_agrees(scripts)
    expected = scripts.flat_map { |script| predict(script) }
    commands = scripts.flatten
    actual = run_script(driver, commands)
    mismatch = expected.each_index.find { |index| expected[index] != actual[index] }
    assert_nil mismatch, mismatch && "line #{mismatch}:\n  model:  #{expected[mismatch]}\n  driver: #{actual[mismatch]}"
    assert_equal expected.size, actual.size
    root_pages = 0
    actual.each do |line|
      root_pages = Integer(line[/ b0:1,0,0,(\d+),/, 1]) if line.start_with?('S ') && line.include?(' b0:')
      assert_whole(line, pages: root_pages) if line.start_with?('S ')
    end
    actual
  end

  # The identity: every page of the root's guarantee is free, released or
  # held by a reserve, a reserve's charge equals what it holds between
  # commands, and what all reserves were admitted is within the root.
  def assert_whole(line, pages:)
    free = Integer(line[/free=(\d+)/, 1])
    released = Integer(line[/rel=(\d+)/, 1])
    reserves = line.scan(/ r\d+:\d+,(\d+),(\d+),\d+/).map { |pair| pair.map { |value| Integer(value) } }
    caches = line.scan(/ b\d+:(?:[^ ,]+,){10}(\d+)/).flatten.map { |value| Integer(value) }
    held = reserves.sum(&:last) + caches.sum
    assert_equal pages, free + released + held, "identity: #{line}"
    reserves.each { |charged, backed| assert_equal charged, backed, "charged equals backed: #{line}" }
  end

  # The random corpus must reach every status and effect it is meant to judge.
  def assert_reaches_every_case(lines)
    results = lines.grep(/\A= /)
    statuses = results.map { |line| status(line) }.uniq
    [0, M::ENOMEM, M::ESTALE, M::EINVAL, M::EBUSY].each { |code| assert_includes statuses, code }
    %w[fire= tomb= freed= refused=0 detached=1].each do |mark|
      assert results.any? { |line| line.include?(" #{mark}") }, "the random corpus never shows #{mark}"
    end
    assert lines.any? { |line| line.start_with?("W ") }, "the random corpus never walks a destroy"
  end

  def status(line) = Integer(line[/\A= (-?\d+)/, 1])

  # The race's final state against the model's definitions, recomputed
  # from the printed facts alone.
  def recompute(line)
    budgets = line.scan(/ b(\d+):(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/).to_h do |fields|
      id, _kind, _depth, _dead, guarantee, _cap, used, carved, lent, _pinned, _threshold, cache = fields.map(&:to_i)
      [id, { guarantee: guarantee, used: used, carved: carved, lent: lent, cache: cache }]
    end
    parents = { 1 => 0, 2 => 1, 3 => 1, 4 => 0, 5 => 4 }
    direct = line.scan(/ r\d+:(\d+),(\d+),/).each_with_object(Hash.new(0)) do |(budget, charged), sums|
      sums[Integer(budget)] += Integer(charged)
    end
    expected = budgets.keys.to_h do |id|
      kids = parents.select { |_kid, parent| parent == id }.keys
      spend = ->(kid) { budgets.fetch(kid).values_at(:used, :carved, :lent).sum }
      [id, { used: direct[id] + budgets.fetch(id).fetch(:cache),
             carved: kids.sum { |kid| budgets.fetch(kid).fetch(:guarantee) },
             lent: kids.sum { |kid| [spend.call(kid) - budgets.fetch(kid).fetch(:guarantee), 0].max } }]
    end
    { expected: expected, actual: budgets.transform_values { |b| b.slice(:used, :carved, :lent) } }
  end

  def deep_borrowing_script
    script = ['root 4096']
    (1...DEPTH_MAX).each { |level| script << "carve #{level - 1} #{ELASTIC} 1 4000" }
    script + ["reserve #{DEPTH_MAX - 1}", 'charge 0 200', 'destroy 1', 'put', 'put']
  end

  def shrink_script
    ['root 100', "carve 0 #{ELASTIC} 10 60", "carve 1 #{ELASTIC} 5 5", 'reserve 1', 'reserve 2', 'charge 0 30',
     'resize 1 10 20', 'charge 0 1', 'charge 1 4', 'release 0 0 15', 'charge 0 1']
  end

  def wall_script
    ['root 100', "carve 0 #{WALL} 30 30", 'reserve 1', 'charge 0 20', 'resize 1 10 20', 'resize 1 10 10',
     'charge 0 1', 'release 0 0 15', 'charge 0 1']
  end

  def closed_backing_script
    ['root 300', "carve 0 #{ELASTIC} 10 200", 'reserve 1', 'charge 0 129 1', 'release 0 0 64', 'charge 0 5']
  end

  def exhaustive_scripts
    shapes = [[0, 1], [0, 0]] # the parents of budgets 1 and 2: a chain and a fan
    priors = [0, 3]
    shapes.product(EXHAUSTIVE_BUDGETS, EXHAUSTIVE_BUDGETS, priors, priors,
                   EXHAUSTIVE_OPERATIONS).map do |parents, first, second, before1, before2, operation|
      script = ['root 8', "carve #{parents[0]} #{first.join(' ')}", "carve #{parents[1]} #{second.join(' ')}",
                'reserve 1', 'reserve 2']
      script << "charge 0 #{before1}" if before1.positive?
      script << "charge 1 #{before2}" if before2.positive?
      script << 'take 0' << operation
      steer(script)
    end
  end

  # The script without the commands that name a budget or reserve an
  # earlier refusal never made.
  def steer(script)
    model = new_model
    script.select do |line|
      name, first = line.split
      kept = case name
             when 'carve', 'reserve', 'resize', 'destroy' then model.budget_ids.include?(Integer(first))
             when 'charge', 'take', 'release' then model.reserve_ids.include?(Integer(first))
             else true
             end
      model.call(line) if kept
      kept
    end
  end

  # Random scripts that the model steers: every id a command names exists.
  def random_scripts(count:, length:, rng:)
    Array.new(count) do
      model = new_model
      pages = 64 + rng.rand(257)
      script = ["root #{pages}"]
      model.call(script.first)
      length.times do
        line = random_command(model, rng, pages)
        model.call(line)
        script << line
      end
      script
    end
  end

  def random_command(model, rng, pages)
    budgets = model.budget_ids
    reserves = model.reserve_ids
    choice = rng.rand(100)
    case choice
    when 0...14 then random_carve(model, rng, pages, budgets)
    when 14...24 then "reserve #{budgets.sample(random: rng)}"
    when 24...50 then reserves.empty? ? 'reap' : random_charge(rng, reserves)
    when 50...56 then reserves.empty? ? 'state' : "take #{reserves.sample(random: rng)}"
    when 56...70 then reserves.empty? ? 'put' : random_release(model, rng, reserves)
    when 70...78 then random_resize(model, rng, pages, budgets)
    when 78...81 then random_pin(model, rng, budgets)
    when 81...86 then random_watch(rng, budgets, pages)
    when 86...91 then budgets.size > 1 ? "destroy #{(budgets - [0]).sample(random: rng)}" : 'state'
    when 91...95 then 'put'
    else 'reap'
    end
  end

  def random_carve(model, rng, pages, budgets)
    return 'state' if budgets.size >= 24

    parent = rng.rand(3).zero? ? budgets.max_by { |id| model.budget(id).depth } : budgets.sample(random: rng)
    guarantee = rng.rand(pages / 4 + 1)
    kind = rng.rand(10).zero? ? 3 : [WALL, ELASTIC].sample(random: rng)
    cap = kind == WALL ? guarantee : guarantee + rng.rand(pages / 2 + 1)
    cap = guarantee + 1 if kind == WALL && rng.rand(15).zero?
    cap = guarantee - 1 if guarantee.positive? && rng.rand(15).zero?
    "carve #{parent} #{kind} #{guarantee} #{cap}"
  end

  def random_charge(rng, reserves)
    reserve = reserves.sample(random: rng)
    return "charge #{reserve} 129 #{rng.rand(3)}" if rng.rand(20).zero?

    "charge #{reserve} #{1 + rng.rand(40)}"
  end

  def random_release(model, rng, reserves)
    id = reserves.sample(random: rng)
    r = model.reserve(id)
    in_use = rng.rand(r.backed - r.pooled + 2)
    pooled = rng.rand(r.pooled + 2)
    "release #{id} #{in_use} #{pooled}"
  end

  # A pin names a page the budget holds, so it never exceeds what is
  # charged there.
  def random_pin(model, rng, budgets)
    id = budgets.sample(random: rng)
    room = model.counters(id).used - model.budget(id).pins
    room.positive? ? "pin #{id} #{1 + rng.rand([room, 2].min)}" : 'state'
  end

  def random_resize(model, rng, pages, budgets)
    id = budgets.sample(random: rng)
    return 'state' if id.zero?

    guarantee = rng.rand(pages / 4 + 1)
    cap = model.budget(id).kind == WALL ? guarantee : guarantee + rng.rand(pages / 2 + 1)
    cap = guarantee + 1 if rng.rand(15).zero?
    "resize #{id} #{guarantee} #{cap}"
  end

  def random_watch(rng, budgets, pages)
    id = budgets.sample(random: rng)
    case rng.rand(4)
    when 0 then "unwatch #{id}"
    when 1 then "detach #{id} #{rng.rand(4)}"
    else "watch #{id} #{rng.rand(4)} #{rng.rand(pages / 2)}"
    end
  end
end
