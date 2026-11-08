# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/object_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the object store (kernel/core/object.c) against ObjectModel. The
# driver runs command scripts through the core and prints one line per
# command; the model predicts each. Bounds: every header reachable from a
# fresh one with at most MAX_NCAPS slots and MAX_REFS references, under
# every operation its contract allows; ids over UNIQUE_IDS creations and
# PERMUTED_COUNTERS random counters under random keys; and the traps the
# contract names.
class ObjectTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_OBJECT_SEED', '20261107'))
  M = ObjectModel
  OPERATIONS = %w[add remove close ref put].freeze
  MAX_NCAPS = 3
  MAX_REFS = 3
  UNIQUE_IDS = 20_000
  PERMUTED_COUNTERS = 500
  # One-line edits of the core, each a failure a test here must catch.
  MUTANTS = {
    'release overwrites a close' => ["(void)atomic_compare_exchange_strong_explicit(&object->state, &live,\n" \
                                     "\t    ERX_OBJ_RELEASED, memory_order_release, memory_order_relaxed);",
                                     "(void)live;\n\tatomic_store(&object->state, ERX_OBJ_RELEASED);"],
    'every close goes on' => ['return (before != ERX_OBJ_DELETED);', 'return (before != 0);'],
    'a capability to a closed object' => ["if (erx_object_state(object) != ERX_OBJ_LIVE)\n\t\treturn (ERX_ESTALE);\n",
                                          ''],
    'zero is an id' => ['return (oid == 0);', 'return (oid == 1);'],
    'no epoch check' => ['if (OBJECT_CHECK_EPOCHS && ref.epoch != erx_effect_thread_epoch())',
                         'if (0)']
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-object-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported object-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @rng = Random.new(SEED)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, 'kernel/core/object.c'), name: 'object')
  end

  # Every header reachable within the bounds, under every operation its
  # contract allows, gives the model's result and next header: the state
  # only advances, a release is reported once when the last slot goes, the
  # first close alone goes on, and no slot is counted on an object that is
  # not live.
  def test_every_reachable_header_agrees_under_every_operation
    scripts = transition_scripts
    assert_operator scripts.size, :>=, 100, 'the exploration reaches too few cases'
    assert_agrees(scripts.map { |script| ['key 1 2 3 4', *script] })
  end

  def test_the_slot_count_stops_at_its_limit
    assert_agrees([['key 1 2 3 4', 'new 0', "ncaps 0 #{M::MASK32}", 'add 0', 'remove 0']])
  end

  # Ids are the permutation of the counter: distinct, never reserved, and
  # each the image of its counter, which the model's inverse recovers.
  def test_ids_are_unique_and_follow_the_counter
    key = random_key
    lines = run_lines(['key ' + key.join(' '), *Array.new(UNIQUE_IDS) { 'new 0' }]).drop(1)
    ids = lines.map { |line| Integer(line.split[2]) }
    assert_equal UNIQUE_IDS, ids.uniq.size
    refute_includes ids, 0
    ids.each_with_index do |oid, counter|
      assert_equal counter, M.invert(key, oid)
    end
  end

  def test_the_permutation_matches_the_model_at_random_counters
    script = Array.new(PERMUTED_COUNTERS) do
      key = random_key
      ["key #{key.join(' ')}", "counter #{@rng.rand(M::MASK64)}", 'new 0']
    end
    assert_agrees([script.flatten])
  end

  # The counter whose image is zero is spent, and the next one's id issued.
  def test_a_reserved_id_is_skipped_and_its_counter_spent
    key = random_key
    counter = M.invert(key, 0)
    assert_equal 0, M.permute(key, counter)
    lines = run_lines(["key #{key.join(' ')}", "counter #{counter}", 'new 0'])
    assert_equal "= 0 #{M.permute(key, counter + 1)} #{counter + 2}", lines.last
  end

  # Creation fails before the counter could wrap, and the failed creation
  # writes nothing.
  def test_the_counter_never_wraps
    key = [5, 6, 7, 8]
    start = M::COUNTER_END - 2
    script = ["key #{key.join(' ')}", "counter #{start}", 'new 0', 'new 1', 'new 1', 'new 0', 'facts 0']
    lines = run_lines(script)
    first = M.mint(key, start)
    second = M.mint(key, first.last)
    assert_equal "= 0 #{first[1]} #{first.last}", lines[2]
    assert_equal "= 0 #{second[1]} #{second.last}", lines[3]
    assert_equal "= #{M::ELIMIT} 0 #{M::COUNTER_END}", lines[4]
    assert_equal "= #{M::ELIMIT} 0 #{M::COUNTER_END}", lines[5]
    assert_equal "= 6 0 #{first[1]} 1", lines[6]
  end

  def test_the_key_is_the_stores_own
    first = run_lines(['key 1 2 3 4', 'new 0', 'new 0', 'key 1 2 3 4', 'new 0', 'new 0', 'key 1 2 3 5', 'new 0'])
    assert_equal first[1..2], first[4..5]
    refute_equal first[1], first[7]
  end

  def test_a_fresh_header_holds_its_fixed_fields
    key = [9, 8, 7, 6]
    assert_equal "= 6 3 #{M.permute(key, 0)} 1", run_lines(["key #{key.join(' ')}", 'new 3', 'facts 3']).last
  end

  # A borrowed reference is good until its thread's next preemption point,
  # and using it after one traps, for a plain use and a counted one alike.
  def test_a_reference_kept_across_a_preemption_point_traps
    lines = run_lines(['key 1 2 3 4', 'new 2', 'lookup 2', 'get', 'hold'])
    assert_equal ['= 0', '= 2', '= 2 2'], lines.drop(2)
    assert_traps(['key 1 2 3 4', 'new 2', 'lookup 2', 'preempt', 'get'])
    assert_traps(['key 1 2 3 4', 'new 2', 'lookup 2', 'preempt', 'hold'])
    assert_equal '= 2', run_lines(['key 1 2 3 4', 'new 2', 'preempt', 'lookup 2', 'get']).last
  end

  # Each breach of a count's contract is a kernel bug and traps.
  def test_broken_counts_trap
    assert_traps(['key 1 2 3 4', 'new 0', 'remove 0'])
    assert_traps(['key 1 2 3 4', 'new 0', 'put 0', 'put 0'])
    assert_traps(['key 1 2 3 4', 'new 0', 'put 0', 'ref 0'])
    assert_traps(['key 1 2 3 4', 'new 0', "refs 0 #{M::MASK32}", 'ref 0'])
  end

  # Host handles are indices into the test store from 1, and nothing else
  # names a record.
  def test_host_handles_index_the_test_store
    lines = run_lines(['store 3', 'handle 0', 'handle 2', 'handle 3', 'from 1', 'from 3', 'from 0', 'from 4',
                       "from #{M::MASK64}", 'store 0', 'from 1'])
    assert_equal ['= 3', '= 1', '= 3', '= 0', '= 0', '= 2', '= -1', '= -1', '= -1', '= 0', '= -1'], lines
  end

  def test_the_slot_list_head_is_kept
    assert_equal ['= 2', '= -1', '= 0'], run_lines(['slots 1 2', 'slots 1 -1', 'slots 4 0'])
  end

  def test_seeded_failures_are_caught
    MUTANTS.each do |name, (original, replacement)|
      mutant = build_driver(mutant_source(name, original, replacement), name: "mutant-#{name.tr(' ', '-')}")
      caught = mutant_caught?(mutant)
      assert caught, "the tests miss the seeded failure: #{name}"
    end
  end

  private

  # The one lookup reads the object through the store (K1, K3): a closed
  # object and an object whose budget is dead are stale to erx_cap_lookup,
  # though erx_cap_read, the pure slot check, accepts their slots; each
  # check, removed from the capability core, fails the program.
  def test_the_lookup_refuses_closed_objects_and_dead_budgets
    @runner.run([build_lookup(File.join(@root, 'kernel/core/cap.c'), name: 'object-lookup')],
                name: 'object-lookup', deadline: 60)
    cap = File.read(File.join(@root, 'kernel/core/cap.c'))
    { 'state' => ["erx_object_state(object) == ERX_OBJ_LIVE &&\n", "\n"],
      'budget' => ['(budget == NULL || !erx_budget_dead(budget))', '(budget == budget)'] }.each do |name, (original, replacement)|
      assert_equal 1, cap.scan(original).size, name
      mutant = File.join(@directory, "cap-#{name}.c")
      File.write(mutant, cap.sub(original, replacement))
      program = build_lookup(mutant, name: "object-lookup-#{name}")
      refute system(program, out: File::NULL, err: File::NULL), "the lookup without its #{name} check passed"
    end
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  # The driver includes the core's private header by its plain name, as
  # the include-form chokepoint requires, from the core's directory; a
  # mutant core finds its own copy of the header beside it first.
  def build_driver(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-DERX_HOST',
                 *@sanitizer_flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'), core,
                 File.join(@root, 'test/fixtures/object_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  # The lookup's program: the capability core with the cores it calls.
  def build_lookup(cap, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-DERX_HOST',
                 *@sanitizer_flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'),
                 '-I', Erx::Generated.path('kernel/generated', root: @root), cap,
                 *%w[kernel/core/object.c kernel/core/budget.c test/fixtures/host_effects.c
                     test/fixtures/object_lookup.c].map { |path| File.join(@root, path) }, '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def mutant_source(name, original, replacement)
    source = File.read(File.join(@root, 'kernel/core/object.c'))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
    directory = File.join(@directory, "source-mutant-#{name.tr(' ', '-')}")
    FileUtils.mkdir_p(directory)
    FileUtils.cp(File.join(@root, 'kernel/core/object_impl.h'), directory)
    path = File.join(directory, 'object.c')
    File.write(path, source.sub(original, replacement))
    path
  end

  # Whether one of the judging checks fails against program: the
  # transitions, the reserved id, or the epoch trap.
  def mutant_caught?(program)
    scripts = transition_scripts.map { |script| ['key 1 2 3 4', *script] }
    return true unless script_lines(program, scripts.flatten) == scripts.flat_map { |script| predict(script) }

    key = [1, 2, 3, 4]
    counter = M.invert(key, 0)
    reserved = script_lines(program, ['key 1 2 3 4', "counter #{counter}", 'new 0']).last
    return true unless reserved == "= 0 #{M.permute(key, counter + 1)} #{counter + 2}"

    trapped(program, ['key 1 2 3 4', 'new 2', 'lookup 2', 'preempt', 'get']).nil?
  end

  def random_key = Array.new(4) { @rng.rand(M::MASK64 + 1) }

  # Each script that explores one transition: a fresh header, the path that
  # reaches a header within the bounds, then one operation its contract
  # allows. The path is the shortest, found breadth first.
  def transition_scripts
    paths = { M::FRESH => [] }
    queue = [M::FRESH]
    scripts = []
    until queue.empty?
      header = queue.shift
      next if header.refs.zero?

      OPERATIONS.each do |op|
        next unless M.allowed?(header, op)

        path = paths.fetch(header) + [op]
        scripts << ['new 0', *path.map { |step| "#{step} 0" }]
        _, after = M.step(header, op)
        next if paths.key?(after) || after.ncaps > MAX_NCAPS || after.refs > MAX_REFS

        paths[after] = path
        queue << after
      end
    end
    scripts
  end

  # The model's lines for one script; key, counter and new are predicted
  # by the id model, every other command by the header model.
  def predict(script)
    key = nil
    counter = 0
    headers = {}
    script.map do |line|
      verb, *args = line.split
      case verb
      when 'key'
        key = args.map { |arg| Integer(arg) }
        counter = 0
        '= 0'
      when 'counter'
        counter = Integer(args[0])
        '= 0'
      when 'new'
        status, oid, counter = M.mint(key, counter)
        headers[args[0]] = M::FRESH if status == M::OK
        "= #{status} #{oid || 0} #{counter}"
      when 'ncaps'
        headers[args[0]] = headers.fetch(args[0]).with(ncaps: Integer(args[1]))
        headers.fetch(args[0]).line(0)
      else
        result, headers[args[0]] = M.step(headers.fetch(args[0]), verb)
        headers.fetch(args[0]).line(verb == 'ref' ? Integer(args[0]) : result)
      end
    end
  end

  def assert_agrees(scripts)
    expected = scripts.flat_map { |script| predict(script) }
    actual = run_lines(scripts.flatten)
    mismatch = expected.each_index.find { |index| expected[index] != actual[index] }
    assert_nil mismatch, mismatch && "line #{mismatch}:\n  model:  #{expected[mismatch]}\n  driver: #{actual[mismatch]}"
    assert_equal expected.size, actual.size
  end

  def run_lines(script) = script_lines(driver, script)

  def script_lines(program, script)
    record = @runner.run([program, write_script(script)], name: 'object-driver', deadline: 300)
    File.read(record.fetch('log')).lines.map(&:chomp).grep(/\A= /)
  rescue Erx::CommandError
    []
  end

  def write_script(script)
    input = File.join(@directory, "script-#{@rng.rand(1 << 62)}.txt")
    File.write(input, script.map { |line| "#{line}\n" }.join)
    input
  end

  # The signal or 128+signal status program ended with, or nil when it
  # ran to its end.
  def trapped(program, script)
    @runner.run([program, write_script(script)], name: 'object-trap', deadline: 60)
    nil
  rescue Erx::CommandError => error
    error.result['signal'] || error.result['exit_status']
  end

  TRAPS = [Signal.list.fetch('TRAP'), Signal.list.fetch('ILL'),
           128 + Signal.list.fetch('TRAP'), 128 + Signal.list.fetch('ILL')].freeze

  def assert_traps(script)
    how = trapped(driver, script)
    assert_includes TRAPS, how, "expected a trap from: #{script.join('; ')}"
  end
end
