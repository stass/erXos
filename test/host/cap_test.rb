# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../fixtures/cap_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# Judges kernel/core/cap.c against CapModel, an independent model written
# from the design. Every scenario is a script of driver commands whose
# whole transcript the model predicts line by line.
#
# * The life exploration is exhaustive: from slots seeded a life or two
#   before their generation or their count is exhausted, every operation
#   is applied in every reachable state until the set of states closes,
#   which it must, since every slot then retires.
# * Seeded walks over two tables, two pages each, cover the free list's
#   order, growth and every route of a pass, with checked kinds and races
#   between plan, take and install.
# * erx_pass_plan is enumerated over a bounded domain of items.
# * Hand cases pin the creation kinds against the design's rows, the
#   table's bounds and the exact counts at which a slot retires.
# * A churn test runs lookups against a writer under ThreadSanitizer.
# * Seeded one-line mutants of the core must each fail.
class CapTest < Minitest::Test
  M = CapModel
  OBJECTS = { 1 => [M::TYPE_NUMBER.fetch(:memory), M::SHARED],
              2 => [M::TYPE_NUMBER.fetch(:gate), M.mask(:call, :dup)],
              3 => [M::TYPE_NUMBER.fetch(:space), M::TYPES.fetch(:space)[1]] }.freeze
  MASKS = [0xffff_ffff, M.mask(:read, :call, :inspect, :give)].freeze
  ROUTES = [[1, 0], [1, 1], [0, 0], [0, 1]].freeze
  DEPTH_MAX = 24

  # A script and the transcript the model predicts for it.
  class Script
    attr_reader :commands, :expected, :tables

    def initialize
      @commands = []
      @expected = []
      @tables = {}
    end

    def emit(command, *lines)
      @commands << command
      @expected.concat(lines)
      self
    end

    def table(id, limit)
      table, status = M.table(limit)
      @tables[id] = table
      emit(format('table %x %x', id, limit), "table #{status}")
    end

    def grow(id, want)
      @tables[id], status, pages = M.grow(@tables.fetch(id), want)
      emit(format('grow %x %x', id, want), format('grow %d %x', status, pages))
    end

    def seed(id, slot, generation, seq)
      @tables[id] = M.seed(@tables.fetch(id), slot, generation, seq)
      emit(format('seed %x %x %x %x', id, slot, generation, seq), 'seed')
    end

    def install(id, object, type, rights)
      @tables[id], status, value = M.install(@tables.fetch(id), object, type, rights)
      emit(format('install %x %x %x %x', id, object, type, rights), format('install %d %x', status, value))
    end

    def clear(id, value, object)
      @tables[id], status = M.clear(@tables.fetch(id), value, object)
      emit(format('clear %x %x %x', id, value, object), "clear #{status}")
    end

    def read(id, value, type, required)
      status, view = M.read(@tables.fetch(id), value, type, required)
      emit(format('read %x %x %x %x', id, value, type, required),
           format('read %d %x %x %x %x %x', status, view.object, view.type, view.rights, view.slot, view.generation))
    end

    def reserve(id, count)
      @tables[id], status = M.reserve(@tables.fetch(id), count)
      emit(format('reserve %x %x', id, count), "reserve #{status}")
    end

    def release(id)
      @tables[id] = M.release(@tables.fetch(id))
      emit(format('release %x', id), 'release')
    end

    def empty(id)
      @tables[id] = @tables.fetch(id).with(emptied: true)
      emit(format('empty %x', id), 'empty')
    end

    def dump(id) = emit(format('dump %x', id), *@tables.fetch(id).dump)

    def rights(kind, mask) = emit(format('rights %x', kind), format('rights %x', mask))

    # Plan a pass from what the model's source table holds, then, on
    # acceptance, take and install it. Race 1 clears the first source
    # and race 2 releases the reservation after the plan, which take must
    # each refuse, changing nothing.
    def pass(from, to, own:, created:, items:, race: 0)
      sources = items.map do |item|
        status, view = M.read(@tables.fetch(from), item.cap, 0, 0)
        M::Source.new(status: status, view: view)
      end
      plan = M.plan(items: items, sources: sources, room: @tables.fetch(to).held.size,
                    from_own: own == 1, to_created: created == 1)
      lines = plan_lines(plan)
      if plan.status == M::OK
        lines.concat(step_lines(from, to, plan, race))
      end
      emit([format('pass %x %x %x %x %x %x', from, to, own, created, items.size, race),
            *items.map { |item| format('item %x %x %x %x %x', item.cap, item.op, item.mask, item.type, item.required) }]
             .join("\n"), *lines)
    end

    def plan_lines(plan)
      [format('plan %d %x %x', plan.status, plan.failed, plan.steps.size),
       *plan.steps.map do |step|
         format('step %d %x %x %x %x %x', step.op, step.slot, step.generation, step.object, step.type, step.rights)
       end]
    end

    def step_lines(from, to, plan, race)
      if race == 1
        first = plan.steps.first
        @tables[from] = M.close(@tables.fetch(from), first.slot, first.generation + 1)
        return ["take #{M::ESTALE}"]
      end

      @tables[to] = M.release(@tables.fetch(to)) if race == 2
      @tables[from], taken = M.pass_take(@tables.fetch(from), plan: plan, held: @tables.fetch(to).held)
      return ["take #{taken}"] unless taken == M::OK

      @tables[to], status, results = M.pass_install(@tables.fetch(to), plan: plan)
      ["take #{M::OK}", "install #{status}",
       *results.map { |value, type, rights| format('result %x %x %x', value, type, rights) }]
    end
  end

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-cap-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported cap-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build_driver(File.join(@root, 'kernel/core/cap.c'), name: 'cap')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_creation_kinds_return_the_designs_rows
    script = Script.new
    M::KINDS.each { |name, rights| script.rights(M.constant("kind_#{name}"), rights) }
    [0, M::KINDS.size + 1, 0xffff_ffff].each { |kind| script.rights(kind, 0) }
    assert_transcript(script)
    M::TYPE_NUMBER.each { |name, number| assert_equal number, M.constant("k_#{name}"), name }
    assert_equal (1..M::KINDS.size).to_a, M::KINDS.keys.map { |name| M.constant("kind_#{name}") }.sort
  end

  def test_shrink_is_an_intersection
    random = Random.new(11)
    pairs = [[0, 0], [0xffff_ffff, 0], [0, 0xffff_ffff], [0xffff_ffff, 0xffff_ffff]] +
            Array.new(200) { [random.rand(1 << 32), random.rand(1 << 32)] }
    output = run_driver(pairs.map { |rights, mask| format('shrink %x %x', rights, mask) })
    assert_equal(pairs.map { |rights, mask| format('shrink %x', rights & mask) }, output)
  end

  def test_table_bounds_and_growth
    script = Script.new
    [0, 1, M::CAPS_MAX + 1].each { |limit| script.table(0, limit) }
    script.table(0, 2).grow(0, 1).grow(0, 2).dump(0)
    script.table(0, 65).grow(0, 63).grow(0, 64).grow(0, 65).dump(0)
    script.table(1, 200).grow(1, 0).grow(1, 130).dump(1).grow(1, 200)
    # Value 0, slot 0, an index past capacity and one with high bits set.
    script.install(1, 1, *OBJECTS.fetch(1))
    [0, 1 << M::SLOT_BITS, 199, 200, (1 << 24) - 1, (1 << 64) - 1].each { |value| script.read(1, value, 0, 0) }
    assert_transcript(script)
  end

  def test_install_refuses_bad_arguments_and_full_and_emptied_tables
    script = Script.new.table(0, 3).grow(0, 2)
    memory = M::TYPE_NUMBER.fetch(:memory)
    script.install(0, 0, memory, 0).install(0, 1, 0, 0).install(0, 1, 10, 0)
    script.install(0, 1, memory, M.mask(:alloc)).install(0, 1, memory, M::SHARED)
    script.install(0, 2, memory, 0).install(0, 3, memory, 0).dump(0)
    script.empty(0).install(0, 4, memory, 0).reserve(0, 1).dump(0)
    assert_transcript(script)
  end

  # Generation 2^40 - 2 is the last issued; a count that leaves no room
  # for a whole further life retires at the closing write.
  def test_retirement_at_the_exact_bounds
    memory, rights = OBJECTS.fetch(1)
    script = Script.new.table(0, 5).grow(0, 4)
    script.seed(0, 1, M::GENERATION_LIMIT - 1, 0)
    script.seed(0, 2, 0, M::FREE_MAX)
    script.seed(0, 3, 0, M::FREE_MAX - 4)
    script.seed(0, 4, M::GENERATION_LIMIT - 2, 0)
    4.times { script.install(0, 1, memory, rights) }
    script.dump(0)
    (1..4).each { |slot| script.clear(0, M.value(slot, script.tables.fetch(0).slots[slot].generation), 1) }
    script.dump(0)
    assert_equal %i[retired retired retired free free], script.tables.fetch(0).slots.map(&:state)
    (1..4).each { |slot| script.read(0, M.value(slot, script.tables.fetch(0).slots[slot].generation), 0, 0) }
    script.reserve(0, 1).release(0).dump(0)
    assert_transcript(script)
    final = script.tables.fetch(0).slots
    assert_equal %i[retired retired retired retired free], final.map(&:state)
    assert_equal M::GENERATION_LIMIT - 1, final[4].generation
    assert_equal M::TERMINAL, final[3].seq
  end

  # K1: one slot reused for a second object; every use of the first
  # object's value, a lookup, a clear and a pass, is stale.
  def test_stale_value_never_names_the_slots_next_object
    assert_transcript(stale_reuse_script)
  end

  def test_life_exploration_closes_and_agrees_with_the_model
    result = explore
    $stdout.puts("cap_test: #{result.fetch(:states)} states, #{result.fetch(:edges)} operations, " \
                 "closed after #{result.fetch(:depth)}")
    assert result.fetch(:closed), "states still unexplored after #{DEPTH_MAX} operations"
    assert_empty result.fetch(:failures), result.fetch(:failures).first(3).join("\n")
    retired = result.fetch(:retired)
    assert_equal [1, 2], retired.to_a.sort, 'every slot of the exploration must retire somewhere'
  end

  def test_seeded_walks_agree_with_the_model
    [1, 2, 3, 4, 5, 6].each { |seed| assert_transcript(walk(seed, steps: 300)) }
  end

  def test_pass_plan_over_a_bounded_domain
    script = Script.new
    singles = plan_items
    ROUTES.each do |own, created|
      [0, 1, 4].each { |room| plan_case(script, own, created, room, singles.first(1) * 5) }
      plan_case(script, own, created, 0, [])
      singles.each { |single| plan_case(script, own, created, 1, [single]) }
      singles.each_slice(64).map(&:first).product(singles).each do |first, second|
        plan_case(script, own, created, 4, [first, second])
      end
    end
    assert_transcript(script)
  end

  def test_mutants_fail
    MUTANTS.each_with_index do |(name, original, replacement), index|
      driver = build_driver(mutant_source(original, replacement, index: index), name: "mutant-#{index}")
      scripts = [walk(1, steps: 300), walk(2, steps: 300), retirement_script, plan_script, stale_reuse_script]
      survived = scripts.all? { |script| transcript_matches?(driver, script) }
      refute survived, "mutant #{name} survived"
    end
  end

  def test_lookups_race_a_writer_under_thread_sanitizer
    program = File.join(@directory, 'cap-churn')
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 '-fsanitize=thread', '-fno-omit-frame-pointer', '-pthread', *include_flags,
                 File.join(@root, 'kernel/core/cap.c'), File.join(@root, 'test/fixtures/cap_churn.c'),
                 '-o', program], name: 'compile-cap-churn', deadline: 60)
    @runner.run([program], name: 'cap-churn', deadline: 120,
                env: Erx::SanitizerEnvironment.call(compiler: compiler))
  end

  # Only the capability core touches a slot's members (K1), by
  # construction: the slot's record, offsets and accessors are in the
  # generated private header build/gen/kernel/generated/cap_slot_impl.h, which the
  # cap-slot-private chokepoint lets only the core and its host tests
  # include. Any other file sees an incomplete type, so a member write,
  # a generated offset or an accessor call fails to compile, while the
  # size and alignment a caller needs to allocate a page stay public. A
  # cast to bytes at an offset copied by hand still compiles (TODO.md).
  def test_a_slots_members_are_out_of_reach_without_the_private_header
    { 'member' => ["void f(erx_cap_slot_t *s) { s->rights = 0; }\n", /incomplete definition of type/],
      'offset' => ["unsigned f(void) { return ERX_CAP_SLOT_OFF_RIGHTS; }\n", /undeclared identifier/],
      'accessor' => ["void f(erx_cap_slot_t *s) { (void)erx_cap_slot_rights_store(s, 0); }\n",
                     /undeclared function/],
      'sequence' => ["int f(void) { return erx_cap_slot_seq_status(0); }\n", /undeclared function/] }
      .each do |name, (body, reason)|
      output, status = syntax_check(name, body)
      refute status.success?, "a file outside the core compiled a slot's #{name}"
      assert_match(reason, output, name)
    end
    output, status = syntax_check('page', "_Static_assert(ERX_CAP_SLOT_SIZE == 64 && ERX_CAP_SLOT_ALIGN == 8, " \
                                          "\"page\");\nsize_t f(erx_cap_slot_t *page) { return page == 0; }\n")
    assert status.success?, output
  end

  # The table's storage contract, as its owner sees it through erx/cap.h:
  # missing, misaligned or short storage is refused, and so is a page that
  # overlaps the table, its directory or a page it holds, since fresh slots
  # written over a page in use would rewind its slots' generations.
  def test_a_table_refuses_storage_it_cannot_own
    program = File.join(@directory, 'cap-storage')
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', Erx::Generated.path('kernel/generated', root: @root),
                 File.join(@root, 'kernel/core/cap.c'), File.join(@root, 'test/fixtures/cap_storage.c'),
                 '-o', program], name: 'compile-cap-storage', deadline: 60)
    @runner.run([program], name: 'cap-storage', deadline: 60)
  end

  # A table's members are the core's alone too (B4): its record is in the
  # hand-written private header kernel/core/cap_impl.h, which the
  # cap-table-private chokepoint lets only the core and its host tests
  # include. Elsewhere a table is an incomplete type, so no file can write
  # its directory, its counts, its free list or its emptied flag, or store
  # a forged page of slots; a caller sizes one with erx_cap_table_size and
  # erx_cap_table_align and hands over storage it no longer types.
  def test_a_tables_members_are_out_of_reach_without_the_private_header
    { 'capacity' => "void f(erx_cap_table_t *t) { t->capacity = 0; }\n",
      'directory' => "void f(erx_cap_table_t *t, void *forged) { t->pages[0] = forged; }\n",
      'free list' => "void f(erx_cap_table_t *t) { t->free_head = 1; }\n",
      'emptied' => "void f(erx_cap_table_t *t) { t->emptied = 0; }\n",
      'by value' => "erx_cap_table_t table;\n" }
      .each do |name, body|
      output, status = syntax_check("table-#{name.tr(' ', '-')}", body)
      refute status.success?, "a file outside the core compiled a table's #{name}"
      assert_match(/incomplete|tentative definition has type/, output, name)
    end
    output, status = syntax_check('table-storage', "size_t f(void) { return erx_cap_table_size() + " \
                                                   "erx_cap_table_align(); }\n")
    assert status.success?, output
  end

  # ERX_CAP_SELF and ERX_CAP_SELF_THREAD through the one lookup: fixed rights
  # the design lists, the same refusals as any capability, and no way to reach
  # them without the caller's view or to touch a slot through them.
  def test_reserved_self_values_resolve_in_the_one_lookup
    self_space = 0xffffff
    self_thread = 0xfffffe
    space = M.constant('k_space')
    thread = M.constant('k_thread')
    space_rights = M::KINDS.fetch('reserved_space')
    thread_rights = M::KINDS.fetch('reserved_thread')
    estale = M.constant('estale')
    etype = M.constant('etype')
    erights = M.constant('erights')
    destroy = M.constant('hr_destroy')
    item = format('item %x %x %x 0 0', self_space, M::COPY, 0xffffffff)
    commands = ['table 0 2', 'grow 0 1',
                format('self 0 %x %x %x', self_space, space, space_rights),
                format('self 0 %x 0 0', self_space),
                format('self 0 %x %x %x', self_thread, thread, thread_rights),
                format('self 0 %x %x 0', self_space, thread),
                format('self 0 %x %x 0', self_thread, space),
                format('self 0 %x %x %x', self_space, space, destroy),
                format('self 0 %x %x %x', self_space, space, M.constant('hr_dup')),
                format('self 0 %x %x %x', self_thread, thread, destroy),
                format('self 0 %x 0 0', self_space | (1 << 24)),
                format('self 0 %x 0 0', 0xfffffd),
                format('self 0 %x 0 0', 0x100000),
                format('read 0 %x 0 0', self_space),
                format('read 0 %x 0 0', self_thread),
                format('clear 0 %x %x', self_space, 0x5a),
                format('clear 0 %x %x', self_thread, 0x7b),
                'table 1 2', 'grow 1 1', 'reserve 1 1',
                'pass 0 1 1 0 1', item,
                'pass 0 1 0 1 1', item]
    lines = run_driver(commands).grep(/\A(?:self|read|clear|plan) /)
    assert_equal [format('self 0 5a %x %x 0 0', space, space_rights),
                  format('self 0 5a %x %x 0 0', space, space_rights),
                  format('self 0 7b %x %x 0 0', thread, thread_rights),
                  "self #{etype} 0 0 0 0 0", "self #{etype} 0 0 0 0 0",
                  "self #{erights} 0 0 0 0 0", "self #{erights} 0 0 0 0 0",
                  "self #{erights} 0 0 0 0 0",
                  "self #{estale} 0 0 0 0 0", "self #{estale} 0 0 0 0 0",
                  "self #{estale} 0 0 0 0 0",
                  "read #{estale} 0 0 0 0 0", "read #{estale} 0 0 0 0 0",
                  "clear #{estale}", "clear #{estale}",
                  "plan #{estale} 0 0", "plan #{estale} 0 0"], lines
  end

  private

  MUTANTS = [
    ['lookup ignores the generation', 'copy.generation != generation)', 'copy.generation + 1 == 0)'],
    ['shrink adds rights', '.bits = rights.bits & mask', '.bits = rights.bits | mask'],
    ['generation wraps', 'generation >= CAP_GENERATION_LIMIT', 'generation > CAP_GENERATION_LIMIT'],
    ['count exhausts', 'seq > CAP_SEQ_FREE_MAX - 2', 'seq > CAP_SEQ_FREE_MAX'],
    ['pass sets ignored', "\t\trights = erx_rights_shrink(rights, pass);\n", "\t\t(void)pass;\n"],
    ['GIVE unchecked', "\t    ERX_HR_GIVE))", "\t    0))"],
    ['LIFO free list', "\tif (table->free_tail == 0)\n\t\ttable->free_head = index;\n\telse\n",
     "\tif (table->free_tail == 0)\n\t\ttable->free_head = index;\n\telse if (0)\n"]
  ].freeze

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def include_flags = [*Erx::Generated.include_flags(root: @root),
                       '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'),
                       '-I', Erx::Generated.path('kernel/generated', root: @root)]

  # Compiles body after the core's public header, as any file outside the
  # core sees it, with the private header's directory on the include path.
  def syntax_check(name, body)
    source = File.join(@directory, "outside-#{name}.c")
    File.write(source, "#include <stddef.h>\n#include \"erx/cap.h\"\n#{body}")
    Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-fsyntax-only',
                    *include_flags, source)
  end

  def build_driver(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, *include_flags, core,
                 File.join(@root, 'test/fixtures/cap_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def mutant_source(original, replacement, index:)
    source = File.read(File.join(@root, 'kernel/core/cap.c'))
    assert_equal 1, source.scan(original).size, "mutant #{index} must edit exactly one place in the core"
    path = File.join(@directory, "mutant-#{index}.c")
    File.write(path, source.sub(original, replacement))
    path
  end

  def run_driver(commands, driver: @driver)
    input = File.join(@directory, 'input.txt')
    File.write(input, [*commands, 'end', ''].join("\n"))
    output, status = Open3.capture2(driver, stdin_data: File.read(input))
    raise Erx::Error, "cap driver failed: #{status.exitstatus}" unless status.success?

    lines = output.split("\n")
    raise Erx::Error, 'cap driver ended early' unless lines.last == 'end'

    lines[0...-1]
  end

  def transcript_matches?(driver, script)
    run_driver(script.commands, driver: driver) == script.expected
  rescue Erx::Error
    false
  end

  def assert_transcript(script)
    actual = run_driver(script.commands)
    mismatch = script.expected.each_index.find { |index| script.expected[index] != actual[index] }
    mismatch ||= script.expected.size unless actual.size == script.expected.size
    return pass unless mismatch

    flunk("transcripts differ at line #{mismatch}: expected #{script.expected[mismatch].inspect}, " \
          "got #{actual[mismatch].inspect}")
  end

  def stale_reuse_script
    memory, shared = OBJECTS.fetch(1)
    gate, call = OBJECTS.fetch(2)
    script = Script.new.table(0, 2).grow(0, 1).install(0, 1, memory, shared)
    old = M.value(1, 0)
    script.clear(0, old, 1).install(0, 2, gate, call).table(1, 2).grow(1, 1).reserve(1, 1)
    script.read(0, old, 0, 0).read(0, old, memory, 0).read(0, M.value(1, 1), 0, 0)
    script.clear(0, old, 1).clear(0, old, 2)
    item = M::Item.new(cap: old, op: M::MOVE, mask: MASKS.first, type: 0, required: 0)
    script.pass(0, 1, own: 0, created: 1, items: [item]).dump(0).dump(1)
  end

  def retirement_script
    memory, rights = OBJECTS.fetch(1)
    script = Script.new.table(0, 3).grow(0, 2).seed(0, 1, M::GENERATION_LIMIT - 2, 0).seed(0, 2, 0, M::FREE_MAX - 2)
    3.times do
      script.install(0, 1, memory, rights).install(0, 1, memory, rights).dump(0)
      (1..2).each { |slot| script.clear(0, M.value(slot, script.tables.fetch(0).slots[slot].generation), 1) }
    end
    script.dump(0)
  end

  def plan_script
    script = Script.new
    plan_items.each { |item| plan_case(script, 1, 0, 1, [item]) }
    script
  end

  # Items over two slots: each status, type, rights, operation, mask,
  # checked type and required right of a small domain.
  def plan_items
    types = M::TYPE_NUMBER.values_at(:memory, :gate, :space, :budget)
    rights = [0, M.mask(:give), M.mask(:give, :dup, :read, :call, :inspect, :map, :code, :exec), 0xffff_ffff]
    live = [1, 2].product(types, rights, [M::COPY, M::MOVE, 7], MASKS, [0, M::TYPE_NUMBER.fetch(:memory)],
                          [0, M.mask(:read)]).map do |slot, type, held, op, mask, checked, required|
      [M::OK, slot, type, held, op, mask, checked, required]
    end
    live + [[M::ESTALE, 1, 0, 0, M::COPY, MASKS.first, 0, 0]]
  end

  def plan_case(script, own, created, room, items)
    sources = items.map do |status, slot, type, rights, *|
      view = status == M::OK ? M::View.new(object: slot, type: type, rights: rights, slot: slot, generation: 3) : M::NO_VIEW
      M::Source.new(status: status, view: view)
    end
    plan_items = items.map { |_s, _slot, _t, _r, op, mask, checked, required| M::Item.new(cap: 0, op: op, mask: mask, type: checked, required: required) }
    plan = M.plan(items: plan_items, sources: sources, room: room, from_own: own == 1, to_created: created == 1)
    lines = items.first(M::MSG_CAPS).zip(sources).map do |(_status, _slot, _type, _rights, op, mask, checked, required), source|
      view = source.view
      format('source %d %x %x %x %x %x %x %x %x %x', source.status, view.object, view.type, view.rights, view.slot,
             view.generation, op, mask, checked, required)
    end
    script.emit([format('plan %x %x %x %x', own, created, room, items.size), *lines].join("\n"), *script.plan_lines(plan))
  end

  # A seeded walk over two tables of two pages each, the second table's
  # slots and counts seeded near exhaustion, with every operation.
  def walk(seed, steps:)
    random = Random.new(seed)
    script = Script.new.table(0, 130).grow(0, 3).table(1, 70).grow(1, 2)
    script.seed(1, 1, M::GENERATION_LIMIT - 3, 0).seed(1, 2, 0, M::FREE_MAX - 6)
    steps.times do
      id = random.rand(2)
      table = script.tables.fetch(id)
      case random.rand(100)
      when 0...25
        object = random.rand(1..3)
        type, rights = OBJECTS.fetch(object)
        script.install(id, object, type, random.rand(4).zero? ? rights & MASKS.last : rights)
      when 25...45
        value, object = some_value(random, table)
        script.clear(id, value, random.rand(8).zero? ? object + 1 : object)
      when 45...60
        value, = some_value(random, table)
        script.read(id, value, [0, *OBJECTS.values.map(&:first)].sample(random: random), [0, M.mask(:give)].sample(random: random))
      when 60...68 then script.reserve(id, random.rand(0..5))
      when 68...74 then script.release(id)
      when 74...76 then script.grow(id, random.rand(1..80))
      when 76 then script.empty(id) if random.rand(4).zero?
      when 77...80 then script.dump(id)
      else
        walk_pass(script, random)
      end
    end
    script.dump(0).dump(1)
  end

  def walk_pass(script, random)
    from = random.rand(2)
    to = random.rand(2)
    own, created = ROUTES.sample(random: random)
    items = Array.new(random.rand(0..4)) do
      value, = some_value(random, script.tables.fetch(from))
      M::Item.new(cap: value, op: [M::COPY, M::MOVE, M::MOVE, 9].sample(random: random), mask: MASKS.sample(random: random),
                  type: [0, 0, 0, OBJECTS.fetch(1).first].sample(random: random), required: [0, 0, M.mask(:read)].sample(random: random))
    end
    script.reserve(to, random.rand(0..4)) if script.tables.fetch(to).held.empty? && random.rand(2).zero?
    race = random.rand(10).zero? && !items.empty? ? random.rand(1..2) : 0
    script.pass(from, to, own: own, created: created, items: items, race: race)
  end

  # A live value of the table, now and then stale or never issued.
  def some_value(random, table)
    live = table.slots.each_with_index.select { |slot, _index| slot.live? }
    return [random.rand(1 << 30), 1] if live.empty? || random.rand(10).zero?

    slot, index = live.sample(random: random)
    generation = random.rand(6).zero? && slot.generation.positive? ? slot.generation - 1 : slot.generation
    [M.value(index, generation), slot.object]
  end

  # Breadth-first over the model's states from a table of two slots, one a
  # generation from exhaustion and one a few writes from the count's end.
  # Each new state's path is replayed once; every operation is then tried
  # from it after a restore, and the driver's transcript is compared with
  # the model's.
  def explore
    base = Script.new.table(0, 3).grow(0, 2).seed(0, 1, M::GENERATION_LIMIT - 3, M::FREE_MAX - 10).seed(0, 2, 0, M::FREE_MAX - 6)
    root = base.tables.fetch(0)
    seen = Set[root]
    frontier = [[root, []]]
    failures = []
    retired = Set.new
    edges = 0
    depth = 0
    until frontier.empty? || depth == DEPTH_MAX
      script = Script.new
      next_frontier = []
      frontier.each do |state, path|
        script.table(0, 3).grow(0, 2).seed(0, 1, M::GENERATION_LIMIT - 3, M::FREE_MAX - 10).seed(0, 2, 0, M::FREE_MAX - 6)
        path.each { |operation| operation.call(script) }
        script.emit('save')
        operations(state).each do |operation|
          script.emit('restore')
          script.tables[0] = state
          operation.call(script)
          script.dump(0)
          after = script.tables.fetch(0)
          edges += 1
          after.slots.each_with_index { |slot, index| retired << index if slot.state == :retired && index.positive? }
          next if seen.include?(after)

          seen << after
          next_frontier << [after, path + [operation]]
        end
      end
      actual = run_driver(script.commands)
      failures << 'transcripts differ' unless actual == script.expected
      frontier = next_frontier
      depth += 1
    end
    { states: seen.size, edges: edges, depth: depth, closed: frontier.empty?, failures: failures, retired: retired }
  end

  # Every operation of the exploration's alphabet in a state: installs of
  # two objects, clears of each live value and of its stale and
  # wrong-object forms, reservations, releases, the emptying, a rendezvous
  # copy and move of each live value within the table, and lookups.
  def operations(state)
    memory, shared = OBJECTS.fetch(1)
    gate, call = OBJECTS.fetch(2)
    live = state.slots.each_with_index.select { |slot, _index| slot.live? }
    ops = [->(s) { s.install(0, 1, memory, shared) }, ->(s) { s.install(0, 2, gate, call) },
           ->(s) { s.reserve(0, 1) }, ->(s) { s.reserve(0, 2) }, ->(s) { s.release(0) }]
    ops << ->(s) { s.empty(0) } unless state.emptied
    live.each do |slot, index|
      value = M.value(index, slot.generation)
      ops << ->(s) { s.clear(0, value, slot.object) }
      ops << ->(s) { s.clear(0, value, slot.object + 1) }
      ops << ->(s) { s.clear(0, M.value(index, slot.generation - 1), slot.object) } if slot.generation.positive?
      ops << ->(s) { s.read(0, value, gate, M.mask(:call)) }
      [M::COPY, M::MOVE].each do |op|
        item = M::Item.new(cap: value, op: op, mask: MASKS.last, type: 0, required: 0)
        ops << ->(s) { s.pass(0, 0, own: 1, created: 0, items: [item]) }
      end
    end
    ops
  end
end
