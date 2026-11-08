# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/space_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# Judges the space core (kernel/core/space.c) against SpaceModel, which
# keeps the tree as the design states it and checks the tree's invariants
# after every command. The driver runs command scripts through the core's
# public interface and prints every result and the whole tree; the model
# predicts each line. Bounds: every sequence of four lifecycle events on a
# child of the first space (LIFECYCLE_EVENTS, 13 events); every
# interleaving of two stop walks with a creation, of one stop walk with two
# creations, and of two destroys each with its stop and deletion walks, on
# a three-level tree, the second walker halting after any of its steps,
# with each deleted space's record released and reaped as soon as no walk
# counts it; the depth limit at ERX_SPACE_DEPTH_MAX; every refusal of a
# creation; the frees of records, which wait for every child's; and random
# creations over random trees.
class SpaceTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_SPACE_SEED', '20261103'))
  M = SpaceModel
  ALL = 'ffffffff'
  BUDGET = "0,1,#{ALL}".freeze
  BUDGET_NO_CODE = "0,1,#{(0xffffffff & ~M.mask(:code)).to_s(16)}".freeze
  PARENT = "0,2,#{ALL}".freeze
  GATE = "0,6,#{ALL},8000".freeze
  GATE_OBJECT = 8000

  # The creator (space 0) makes a child of PARENT_ID in plan slot SLOT.
  def self.create(slot, parent, creator: 0, flags: 0, limit: 16, budget: BUDGET, gate: GATE)
    ["plan #{slot} #{creator} #{parent} #{flags} #{limit} #{budget} #{PARENT} #{gate}", "attach #{slot}"]
  end

  def create(...) = self.class.create(...)

  # Spaces 1 to 3: 1 under the first, 2 under 1 by 1's own creation, and
  # 3 under 1 by the first's.
  DEEP = ['first', *create(0, 0), *create(1, 1, creator: 1), *create(2, 1)].freeze
  # A stopped and a closed parent outside the creator's subtree: the
  # parent's state is refused before its chain is walked.
  DEAD_PARENTS = {
    [*DEEP, 'stop 3 1 1', "plan 4 2 3 0 16 #{BUDGET} #{PARENT} #{GATE}"] => M::EDEAD,
    [*DEEP, 'close 3', "plan 4 2 3 0 16 #{BUDGET} #{PARENT} #{GATE}"] => M::ESTALE
  }.freeze
  # A chain of three below the first: 1, 2 under 1 and 3 under 2.
  CHAIN = ['first', *create(0, 0), *create(1, 1), *create(2, 2)].freeze
  # The deletion walk from 1 is at 3, holding it, when 2, between it and
  # the root, is released; its way back up then reads 2's record.
  DELETE_ASCENT = [*CHAIN, 'close 1', 'stop 1 1 1', 'walk 0 1', *(['step 0'] * 12), 'delete 0 1', 'dstep 0', 'dstep 0',
                   'release 2', *(['dstep 0'] * 3)].freeze
  # The stop walk from 1 is at 3, holding it, when a second walk walks 2,
  # a third deletes it and 2 is released; the first walk's way back up
  # then reads 2's record.
  STOP_ASCENT = [*CHAIN, 'stop 1 1 1', 'walk 0 1', *(['step 0'] * 4), 'walk 1 2', *(['step 1'] * 6),
                 'close 2', 'delete 2 2', *(['dstep 2'] * 3), 'release 2', *(['step 0'] * 6)].freeze
  # 2 is released while its child 3 lives: its record waits, and goes in
  # the reaper's round after 3's free.
  DEFERRED_FREE = [*CHAIN, 'close 2', 'stop 2 1 1', 'walk 0 2', *(['step 0'] * 8), 'delete 0 2', *(['dstep 0'] * 4),
                   'release 2', 'reap', 'release 3', 'reap', 'reap'].freeze
  # A creation refused at its attach, by the stop of a parent that took
  # the plan: its record goes by the free steps, and the parent counts
  # nothing for it.
  REFUSED_RECORD = ['first', *create(0, 0), "plan 1 0 1 0 16 #{BUDGET} #{PARENT} #{GATE}", 'stop 1 1 1',
                    'attach 1', "plan 2 0 0 0 16 #{BUDGET} #{PARENT} #{GATE}", 'close 0', 'attach 2'].freeze

  # S (1), P (2) that S created and C (3) that S created under P.
  PINNED_TREE = ['first', *create(0, 0), *create(1, 1, creator: 1), *create(2, 2, creator: 1)].freeze
  # P's destroy up to the end of its stop walk.
  STOP_P = ['close 2', "stop 2 #{M::EXIT_RELEASED} 77", 'walk 0 2', *(['step 0'] * 6)].freeze
  # The walk of P's destroy, once P's stop walk is done.
  DESTROY_P_WALK = ['delete 1 2', *(['dstep 1'] * 3)].freeze
  # P's destroy, by its budget's destruction: close, stop and the two walks.
  DESTROY_P = [*STOP_P, *DESTROY_P_WALK].freeze

  # C's record waits at its gate and P's has been posted but not placed when
  # P's destroy begins its deletion; neither is ever received. A later post of
  # either changes nothing.
  RECORDS_NOBODY_TAKES = [*PINNED_TREE, *STOP_P, 'post 3', 'place 3', 'post 2', *DESTROY_P_WALK, 'place 2', 'post 3',
                          'exit 3', 'exit 2', 'ready 3', 'ready 2', 'release 2', 'release 3', 'reap', 'reap'].freeze
  # C's receiver has died, so the withdrawal cannot reach its record; its
  # drain's placement finds the deletion begun.
  RECEIVER_DIED = [*PINNED_TREE, *STOP_P, 'post 3', 'place 3', 'dead 3', *DESTROY_P_WALK, 'ready 3', 'place 3', 'ready 3',
                   'exit 3'].freeze
  # P's and C's deletions begin first, and their posts then find them deleted.
  LATE_POSTS = [*PINNED_TREE, *STOP_P, *DESTROY_P_WALK, 'post 3', 'post 3', 'post 2'].freeze
  # C's own destroy closes it, and P's walk unlinks it and owns it: C's own
  # begin, after its stop walk, says DONE.
  PARENT_WALK_FIRST = [*PINNED_TREE, 'close 3', *DESTROY_P, 'walk 2 3', 'step 2', 'step 2', 'delete 2 3', 'dstep 2'].freeze
  # C's own destroy unlinks it first: P's walk never sees it.
  OWN_WALK_FIRST = [*PINNED_TREE, 'close 3', "stop 3 #{M::EXIT_RELEASED} 5", 'walk 2 3', 'step 2', 'step 2', 'delete 2 3',
                    'close 2', "stop 2 #{M::EXIT_RELEASED} 7", 'walk 0 2', 'step 0', 'step 0', 'delete 1 2', 'dstep 1'].freeze

  # Space 1, a child of the first, with one thread.
  LIFECYCLE_BASE = ['first', *create(0, 0), 'thread 1'].freeze
  # Each event a sequence of commands; a walk's steps run past its end,
  # where each prints DONE again.
  LIFECYCLE_EVENTS = [
    ['stop 1 7 9'], ['close 1'], ['stop 0 3 4'],
    ['walk 0 1', *(['step 0'] * 10)], ['walk 1 0', *(['step 1'] * 14)],
    ['delete 0 1', *(['dstep 0'] * 4)],
    ['admit 1 1'], ['admit 1 2'], ['admit 1 3'], ['admit 1 9'],
    create(1, 1), ['thread 1'], ["detach 1 #{GATE_OBJECT}"]
  ].freeze
  LIFECYCLE_DEPTH = 4
  # The most transitions an interleaving test may explore.
  EXPLORE_BOUND = 60_000

  # One-line edits of the core, each a failure the design says the tests
  # must catch.
  MUTANTS = {
    'attach ignores a stopped parent' => ['ERX_SPACE_ADMIT_MAPPING && run_load(space) != ERX_SPACE_LIVE)',
                                         'ERX_SPACE_ADMIT_MAPPING && run_load(space) == 99)'],
    'attach ignores a closed parent' => ["memory_order_relaxed))\n\t\treturn (ERX_ESTALE);\n\tif (what",
                                         "memory_order_relaxed) && 0)\n\t\treturn (ERX_ESTALE);\n\tif (what"],
    'child joins at the end' => ['list_insert_after(&parent->children, &space->in_parent);',
                                 'list_insert_after(parent->children.prev, &space->in_parent);'],
    'walked child stays in place' => ["\t\t\tlist_remove(&cursor->in_parent);\n\t\t\tlist_insert_after(cursor->parent->children.prev,\n\t\t\t    &cursor->in_parent);",
                                      "\t\t\t(void)0;"],
    'walk descends into walked children' => ['run_load(child) < ERX_SPACE_WALKED', 'run_load(child) <= ERX_SPACE_WALKED'],
    'walk never stops what it enters' => ["\tif (run_load(cursor) == ERX_SPACE_LIVE) {\n\t\tspace_stop",
                                          "\tif (0) {\n\t\tspace_stop"],
    'walk skips the kills' => ["\tif (unkilled)\n\t\treturn (ERX_STOP_KILL);", "\t(void)unkilled;"],
    'deletion leaves the space listed' => ["\tif (space->parent != NULL)\n\t\tlist_remove(&space->in_parent);\n\treturn ((old", "\treturn ((old"],
    'deletion leaves the space open' => ['atomic_store_explicit(&space->closed, true, memory_order_relaxed);', '(void)0;'],
    'a deleting root is deleted again' => ["\tif (run == ERX_SPACE_DELETING) {\n\t\t/* Another", "\tif (0) {\n\t\t/* Another"],
    'a deleting root is refused' => ['if (run != ERX_SPACE_WALKED && run != ERX_SPACE_DELETING)', 'if (run != ERX_SPACE_WALKED)'],
    'a post ignores a deletion begun' => ['return ((old & EXIT_DELETED) != 0 ? ERX_SPACE_POST_DROP :', 'return (0 ? ERX_SPACE_POST_DROP :'],
    'a second post queues again' => ['if ((old & EXIT_POSTED) != 0)', 'if (0)'],
    'a deletion misses a posted record' => ['return ((old & EXIT_POSTED) != 0);', 'return ((old & 0) != 0);'],
    'a deletion leaves the exit word' => ["old = atomic_fetch_or_explicit(&space->exit_bits, EXIT_DELETED,\n\t    memory_order_relaxed);", 'old = atomic_load_explicit(&space->exit_bits, memory_order_relaxed);'],
    'a record waits after its deletion' => ["return ((atomic_load_explicit(&space->exit_bits, memory_order_relaxed) &\n\t    EXIT_DELETED) == 0);", "(void)space;\n\treturn (true);"],
    'deletion begins at an open root' => ["if (root == NULL ||\n\t    !atomic_load_explicit(&root->closed, memory_order_relaxed))", 'if (root == NULL)'],
    'deletion begins before the walk is done' => ['if (run != ERX_SPACE_WALKED && run != ERX_SPACE_DELETING)',
                                                  'if (run == ERX_SPACE_LIVE)'],
    'depth limit one level late' => ['parent->depth >= ERX_SPACE_DEPTH_MAX', 'parent->depth > ERX_SPACE_DEPTH_MAX'],
    'parent chain unchecked' => ["\tif (!space_at_or_below(parent, self))\n\t\treturn (ERX_ERIGHTS);",
                                 "\tif (0 && !space_at_or_below(parent, self))\n\t\treturn (ERX_ERIGHTS);"],
    'JIT from the creator ignored' => ['(self->flags & ERX_SPACE_JIT) == 0)', '1)'],
    'close accepted twice' => ["\tif (atomic_exchange_explicit(&space->closed, true, memory_order_relaxed))\n\t\treturn (ERX_ESTALE);",
                               "\t(void)atomic_exchange_explicit(&space->closed, true, memory_order_relaxed);"],
    'stop status overwritten' => ["\tif (run_load(space) != ERX_SPACE_LIVE)\n\t\treturn (false);\n\tspace->status",
                                  "\tif (run_load(space) != ERX_SPACE_LIVE) {\n\t\tspace->status = status;\n\t\treturn (false);\n\t}\n\tspace->status"],
    'detach takes any gate' => ['expected = gate;', 'expected = erx_space_fault_gate(space);'],
    'parent chain walked before the parent is checked' =>
      ["\terror = erx_space_admit(parent, ERX_SPACE_ADMIT_CHILD);\n\tif (error != ERX_OK)\n\t\treturn (error);\n" \
       "\tif (!space_at_or_below(parent, self))\n\t\treturn (ERX_ERIGHTS);",
       "\tif (!space_at_or_below(parent, self))\n\t\treturn (ERX_ERIGHTS);\n" \
       "\terror = erx_space_admit(parent, ERX_SPACE_ADMIT_CHILD);\n\tif (error != ERX_OK)\n\t\treturn (error);"],
    'descent forgets the held space' => ["\t\twalk->drop = walk->held;\n\t\twalk->held = child;\n\t\treturn (ERX_STOP_DESCEND);",
                                         "\t\treturn (ERX_STOP_DESCEND);"],
    'deletion forgets the held space' => ["\t\twalk->drop = walk->held;\n\t\twalk->held = child;\n\t\treturn (ERX_DELETE_SPACE);",
                                          "\t\treturn (ERX_DELETE_SPACE);"],
    'done leaves the held reference unnamed' => ["\t\twalk->drop = walk->held;\n\t\twalk->held = NULL;\n\t\treturn (ERX_STOP_DONE);",
                                                 "\t\twalk->held = NULL;\n\t\treturn (ERX_STOP_DONE);"],
    'delete done leaves the held reference unnamed' => ["\t\twalk->drop = walk->held;\n\t\twalk->held = NULL;\n\t\treturn (ERX_DELETE_DONE);",
                                                        "\t\twalk->held = NULL;\n\t\treturn (ERX_DELETE_DONE);"],
    'stop step keeps a stale drop' => ["\twalk->drop = NULL;\n\tcursor = walk->cursor;\n\tif (cursor == NULL)\n\t\treturn (ERX_STOP_DONE);",
                                       "\tcursor = walk->cursor;\n\tif (cursor == NULL)\n\t\treturn (ERX_STOP_DONE);"],
    'delete step keeps a stale drop' => ["\twalk->drop = NULL;\n\twalk->withdraw = false;", "\twalk->withdraw = false;"],
    'delete step keeps a stale withdrawal' => ["\twalk->drop = NULL;\n\twalk->withdraw = false;", "\twalk->drop = NULL;"],
    'a new record has no own hold' => ["space->parent = NULL;\n\tatomic_init(&space->holds, 1);", 'space->parent = NULL;'],
    'a new record keeps a garbage parent' => ["space->parent = NULL;\n\tatomic_init(&space->holds, 1);", 'atomic_init(&space->holds, 1);'],
    'parent freed before its child' => ['return (space_unhold(space));', "(void)space_unhold(space);\n\treturn (true);"],
    'child does not hold its parent' => ['atomic_fetch_add_explicit(&parent->holds, 1, memory_order_relaxed);', '(void)0;'],
    'free leaves the parent hold' => ['if (parent == NULL || !space_unhold(parent))', 'if (parent == NULL || 1)'],
    'free drops the parent hold twice' => ['if (parent == NULL || !space_unhold(parent))',
                                             'if (parent == NULL || (space_unhold(parent), !space_unhold(parent)))']
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-space-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported space-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, 'kernel/core/space.c'), name: 'space', flags: @sanitizer_flags)
  end

  def test_every_lifecycle_event_in_every_reachable_state
    scripts = LIFECYCLE_EVENTS.repeated_permutation(LIFECYCLE_DEPTH).map { |events| LIFECYCLE_BASE + events.flatten }
    assert_equal 13**4, scripts.size
    lines = assert_agrees(scripts)
    runs = lines.grep(/\AS /).flat_map { |line| line.scan(/ 1:0,1,([LSWD]),([01]),/) }.uniq
    reachable = [*%w[L S W].product(%w[0 1]), %w[D 1]]
    assert_equal reachable.sort, runs.sort, 'every run state, open and closed, is reached, and a deleting space is closed'
  end

  # K27: two stop walks of overlapping trees, the inner walker halting
  # after any of its steps, race a creation under each root; the outer
  # walk must finish everything below it by itself.
  def test_two_stop_walks_racing_creations
    base = ['first', *create(0, 0), *create(1, 1), 'thread 1', 'thread 1', 'thread 2',
            "plan 5 0 2 0 16 #{BUDGET} #{PARENT} #{GATE}", "plan 6 0 1 0 16 #{BUDGET} #{PARENT} #{GATE}"]
    actors = { outer: stop_walk_actor(walk: 0, root: 1, status: 11),
               inner: stop_walk_actor(walk: 1, root: 2, status: 21),
               create: once_actor('attach 5'), create_near: once_actor('attach 6') }
    scripts = explore(base, actors, finished: %i[outer create create_near])
    assert_equal 3170, scripts.size
    lines = assert_agrees(scripts)
    assert lines.any? { |line| line == "= #{M::EDEAD} -" }, 'a creation after the stop is refused'
    assert lines.any? { |line| line.match?(/\A= 0 3\z/) }, 'a creation before the stop is admitted'
  end

  # K27: one stop walk races two creations at different levels.
  def test_a_stop_walk_racing_two_creations
    base = ['first', *create(0, 0), *create(1, 1), 'thread 1', 'thread 2',
            "plan 5 0 1 0 16 #{BUDGET} #{PARENT} #{GATE}", "plan 6 0 2 0 16 #{BUDGET} #{PARENT} #{GATE}"]
    actors = { outer: stop_walk_actor(walk: 0, root: 1, status: 11),
               near: once_actor('attach 5'), far: once_actor('attach 6') }
    scripts = explore(base, actors, finished: actors.keys)
    assert_equal 179, scripts.size
    assert_agrees(scripts)
  end

  # K27: two destroys, each with its stop and deletion walks, overlap: the
  # outer deletion begins only once its own stop walk is done, and every
  # space below is deleted by the walk that unlinked it. The inner destroy
  # may have closed its root before the outer walk reaches it, or come
  # after, when its close says ESTALE and its begin DONE.
  def test_overlapping_stop_and_deletion_walks
    base = ['first', *create(0, 0), *create(1, 1), *create(2, 2), *create(3, 2), 'thread 1', 'thread 3',
            "plan 5 0 4 0 16 #{BUDGET} #{PARENT} #{GATE}"]
    actors = { outer: destroy_actor(walk: 0, root: 1, status: 11),
               inner: destroy_actor(walk: 1, root: 2, status: 21),
               create: once_actor('attach 5'), release: release_actor(callers: { 0 => 1, 1 => 2 }), reap: reap_actor }
    on_released = 0
    walking_released = lambda do |model|
      walks = model.stop_walks.values + model.delete_walks.values
      on_released += 1 if walks.any? { |walk| walk.cursor && model.spaces.fetch(walk.cursor).released }
    end
    scripts = explore(base, actors, finished: %i[outer inner create], observe: walking_released) do |model|
      deleted = model.subtree(1).map { |id| model.spaces.fetch(id).then { |space| [space.run, space.closed] } }.uniq
      assert_equal [[:D, true]], deleted, 'both walks done: every space below the outer root is deleted'
    end
    assert_equal 12_730, scripts.size
    assert_operator on_released, :>, 0, 'a walk is on a released record that its held space keeps'
    assert_agrees(scripts)
  end

  # K27: a child stopped and deleted leaves its parent's list, closed; a
  # sibling is then stopped, and the parent's own stop and deletion must
  # reach it.
  def test_parent_deletion_reaches_a_sibling_stopped_after_another_left
    script = ['first', *create(0, 0), *create(1, 1), *create(2, 1), 'thread 3',
              'close 2', 'stop 2 1 1', 'walk 0 2', 'step 0', 'step 0', 'delete 0 2', 'dstep 0',
              'stop 3 2 2', 'close 1', 'stop 1 3 3', 'walk 1 1', *(['step 1'] * 8), 'delete 1 1', *(['dstep 1'] * 4)]
    final = assert_agrees([script]).last
    assert_match(/ 2:1,2,D,1,/, final, 'the sibling that left did so by its deletion')
    assert_match(/ 3:1,2,D,1,\d+,\d+,\d+,\h+,2,2,1,1,\[\],k\z/, final, 'the sibling is deleted, its thread killed')
    assert_match(/ 1:0,1,D,.*,1,3,\[\],/, final)
  end

  # The deletion walk reaches every space below its root, none of which was
  # closed by anyone else: each is closed, deleting and on no list, and the
  # reaper frees the records bottom up, a level per round.
  def test_a_deletion_reaches_every_space_below
    script = [*PINNED_TREE, *create(3, 3, creator: 1), *create(4, 2, creator: 1), *create(5, 5, creator: 1),
              'thread 4', 'thread 6', 'close 2', 'stop 2 5 6', 'walk 0 2', *(['step 0'] * 20), 'delete 1 2',
              *(['dstep 1'] * 11), *(2..6).map { |id| "release #{id}" }, *(['reap'] * 3)]
    lines = assert_agrees([script])
    after_walk = lines[2 * script.index('release 2') - 1]
    (2..6).each do |id|
      assert_match(/ #{id}:\d+,\d+,D,1,/, after_walk, "space #{id} is closed and deleting")
      assert_match(/ #{id}:[^ ]*,\[\],/, after_walk, "space #{id} lists nothing")
    end
    assert_equal 5, lines.drop(2 * script.index('release 2')).grep(/\A= (\d+)\z/).sum { |line| line[2..].to_i },
                 'every record is freed'
    assert_match(/\AS 0:\S+ 1:0,1,L,[^ ]*\z/, lines.last, 'only the destroyer is left')
  end

  # The walk that takes a space off its parent's list owns its deletion,
  # whoever closed the space; a destroy that finds it closed stops at its close.
  def test_the_walk_that_unlinks_a_space_owns_its_deletion
    lines = assert_agrees([PARENT_WALK_FIRST])
    assert_equal '= 0 3', lines[-4], "C's own begin says DONE"
    assert_equal '= DONE -1 -1 -1', lines[-2]

    lines = assert_agrees([OWN_WALK_FIRST])
    assert_equal '= 0 1', lines[2 * OWN_WALK_FIRST.index('delete 2 3')], "C's own begin unlinks it"
    assert_equal '= DONE -1 -1 -1', lines[-2], "P's walk finds no child"

    assert_equal "= #{M::ESTALE}", assert_agrees([[*PINNED_TREE, *DESTROY_P, 'close 3']])[-2], "C's destroy stops at its close"
  end

  # K27: a sub-space released while its parent lives leaves the tree; the
  # parent's later stop walks only what is left.
  def test_release_of_a_sub_space_of_a_live_parent
    script = ['first', *create(0, 0), *create(1, 1), *create(2, 1), 'thread 2',
              'close 2', "stop 2 #{M::EXIT_RELEASED} 77", 'walk 0 2', *(['step 0'] * 4), 'delete 0 2', 'dstep 0',
              'admit 1 1', 'stop 1 5 6', 'walk 1 1', *(['step 1'] * 6)]
    lines = assert_agrees([script])
    assert_match(/ 2:1,2,D,1,\d+,\d+,\d+,\h+,#{M::EXIT_RELEASED},77,1,1,\[\],k /, lines.last)
    assert_match(/ 3:1,2,W,0,\d+,\d+,\d+,\h+,#{M::EXIT_PARENT},6,0,1,\[\],/, lines.last)
  end

  # S (1) creates P (2) on a budget another party holds, and C (3) under P
  # on its own, and keeps C's capability, so nothing closes C. The other
  # party destroys P's budget, which runs P's destroy: C's capability goes
  # stale, and nothing S holds keeps C's record, P's or P's budget's
  # tombstone, which the reaper frees a level per round.
  def test_a_kept_capability_does_not_pin_a_deleted_tree
    lines = assert_agrees([[*PINNED_TREE, *DESTROY_P, 'admit 3 3', 'ready 3', 'ready 2',
                            'release 2', 'release 3', 'reap', 'reap']])
    results = lines.grep(/\A= /).last(7)
    assert_equal "= #{M::ESTALE}", results[0], "C's capability still works, so S can keep it"
    assert_equal ['= 1', '= 1'], results[1, 2], "C's capability keeps C's record and P's"
    assert_equal ['= 0', '= 1', '= 1', '= 0'], results[3, 4], 'C goes at once, P in the next round'
    assert_match(/\AS 0:\S+ 1:0,1,L,[^ ]*\z/, lines.last, 'only S is left')
  end

  # S never receives on its gate. A record that waits there is withdrawn, one
  # posted but not placed drops at its placement, and neither keeps its space.
  # The core decides each; the driver's queue and count stand in for the
  # kernel's, so K27's domain tests prove the withdrawal itself.
  def test_an_undelivered_exit_record_does_not_pin_a_deleted_tree
    results = assert_agrees([RECORDS_NOBODY_TAKES]).grep(/\A= /).last(8)
    assert_equal ['= D 2', '= D 2'], results[0, 2], 'each record is dropped and counted at the gate'
    assert_equal ['= 1', '= 1'], results[2, 2], 'a record no one takes keeps its space'
    assert_equal ['= 0', '= 1', '= 1', '= 0'], results[4, 4]
  end

  # A receiver dies with the record queued, past the reach of the withdrawal:
  # until its drain the record waits, and the drain's placement drops it.
  def test_a_record_whose_receiver_died_goes_at_its_drain
    assert_equal ['= 0', '= D 1', '= 1', '= D 1'], assert_agrees([RECEIVER_DIED]).grep(/\A= /).last(4)
  end

  # A post after the deletion has begun drops the record at once, at most once.
  def test_a_post_after_the_deletion_began_drops_its_record
    assert_equal ['= DROP D 1', '= NONE D 1', '= DROP D 2'], assert_agrees([LATE_POSTS]).grep(/\A= /).last(3)
  end

  # A record taken before the deletion is no one's to withdraw: a flow that
  # takes it first loses nothing, and the gate counts no drop.
  def test_a_record_taken_before_the_deletion_is_not_dropped
    lines = assert_agrees([[*PINNED_TREE, *STOP_P, 'post 3', 'place 3', 'take 3', 'post 2', 'place 2', 'take 2',
                            *DESTROY_P_WALK, 'exit 3', 'exit 2']])
    assert_equal ['= T 0', '= T 0'], lines.grep(/\A= /).last(2)
  end

  # Every order of a destroy with both posts, placements and receipts: each
  # record ends taken or dropped and counted, never waiting at the gate.
  def test_posts_racing_a_deletion
    actors = %w[3 2].to_h do |id|
      [id, lambda do |model, history|
        next "post #{id}" unless history.include?("post #{id}")
        next "place #{id}" unless history.include?("place #{id}")

        model.spaces.fetch(Integer(id)).exit == :W && !history.include?("take #{id}") ? "take #{id}" : nil
      end]
    end
    actors[:destroy] = destroy_actor(walk: 0, root: 2, status: 7)
    ended = []
    scripts = explore(PINNED_TREE, actors, finished: [:destroy, '2', '3']) do |model|
      ended.concat(model.exit_states.first.values_at(2, 3))
    end
    assert_empty ended.uniq - %i[T D], 'no record waits once the walk has ended'
    assert_includes ended, :D
    assert_includes ended, :T
    assert_agrees(scripts)
  end

  # The first space is the one without a parent, gate or flags; no
  # creation makes another, and its stop walk finishes on no list.
  def test_the_first_space_is_the_only_one_without_a_parent
    script = ['first', *create(0, 0), "plan 1 0 self #{M::JIT} 16 #{BUDGET_NO_CODE} #{PARENT} #{GATE}",
              'close 0', 'stop 0 1 2', 'walk 0 0', *(['step 0'] * 8), 'delete 0 0', *(['dstep 0'] * 3)]
    lines = assert_agrees([script])
    assert_equal "= #{M::ERIGHTS} 0 0", lines[6], 'the first space allows no JIT objects'
    assert_match(/\AS 0:-1,0,D,1,0,64,0,0,1,2,1,2,\[\],/, lines.last)
    assert_match(/ 1:0,1,D,1,0,16,#{GATE_OBJECT},1000,#{M::EXIT_PARENT},2,1,1,\[\],\z/, lines.last)
  end

  # Every refusal of erx_space_plan, in its order of checks.
  def test_every_invalid_creation_is_refused
    cases = {
      "plan 4 0 self 2 16 #{BUDGET} #{PARENT} #{GATE}" => M::EINVAL,
      "plan 4 0 self 0 1 #{BUDGET} #{PARENT} #{GATE}" => M::EINVAL,
      "plan 4 0 self 0 #{M::CAPS_MAX + 1} #{BUDGET} #{PARENT} #{GATE}" => M::EINVAL,
      "plan 4 0 self 0 #{M::CAPS_MAX} #{BUDGET} #{PARENT} #{GATE}" => 0,
      "plan 4 0 self 0 16 #{M::ESTALE},1,#{ALL} #{PARENT} #{GATE}" => M::ESTALE,
      "plan 4 0 self 0 16 0,6,#{ALL} #{PARENT} #{GATE}" => M::ETYPE,
      "plan 4 0 self 0 16 0,1,#{M.mask(:alloc).to_s(16)} #{PARENT} #{GATE}" => M::ERIGHTS,
      "plan 4 0 self 0 16 0,1,#{M.mask(:spaces).to_s(16)} #{PARENT} #{GATE}" => M::ERIGHTS,
      "plan 4 0 1 0 16 #{BUDGET} #{M::ESTALE},2,#{ALL} #{GATE}" => M::ESTALE,
      "plan 4 0 1 0 16 #{BUDGET} 0,1,#{ALL} #{GATE}" => M::ETYPE,
      "plan 4 0 1 0 16 #{BUDGET} 0,2,#{M.mask(:map, :threads, :stop).to_s(16)} #{GATE}" => M::ERIGHTS,
      "plan 4 0 1 0 16 #{BUDGET} 0,2,#{ALL},102 #{GATE}" => M::EINVAL,
      "plan 4 0 self 0 16 #{BUDGET} #{PARENT} #{M::ESTALE},6,#{ALL}" => M::ESTALE,
      "plan 4 0 self 0 16 #{BUDGET} #{PARENT} 0,2,#{ALL}" => M::ETYPE,
      "plan 4 0 self 0 16 #{BUDGET} #{PARENT} 0,6,#{M.mask(:call).to_s(16)}" => M::ERIGHTS,
      "plan 4 1 self 1 16 #{BUDGET_NO_CODE} #{PARENT} #{GATE}" => M::ERIGHTS,
      "plan 4 1 self 1 16 #{BUDGET} #{PARENT} #{GATE}" => 0,
      "plan 4 2 3 0 16 #{BUDGET} #{PARENT} #{GATE}" => M::ERIGHTS,
      "plan 4 1 0 0 16 #{BUDGET} #{PARENT} #{GATE}" => M::ERIGHTS,
      "plan 4 1 2 0 16 #{BUDGET} #{PARENT} #{GATE}" => 0,
      "plan 4 2 self 0 16 #{BUDGET} #{PARENT} #{GATE}" => 0,
      'attach 7' => M::EINVAL
    }
    scripts = cases.keys.map { |command| DEEP + [command] }
    results = assert_agrees(scripts).each_slice(2).map(&:first).each_slice(DEEP.size + 1).map(&:last)
    assert_equal cases.values, results.map { |line| Integer(line[/\A= (-?\d+)/, 1]) }
  end

  def test_a_dead_parent_is_refused_before_its_chain_is_walked
    last_plans = DEAD_PARENTS.keys.map { |script| assert_agrees([script]).grep(/\A= -?\d+ [01] \d+\z/).last }
    assert_equal DEAD_PARENTS.values, last_plans.map { |line| Integer(line[/\A= (-?\d+)/, 1]) }
  end

  # A walk counts only its root and its held space, the last it descended
  # into: a space between them that is released keeps its record while
  # the held space's lives, so each walk's way back up reads a live record
  # (a freed one is poisoned, and caught under AddressSanitizer).
  def test_a_walk_goes_back_up_only_into_live_records
    [DELETE_ASCENT, STOP_ASCENT].each do |script|
      lines = assert_agrees([script])
      released = 2 * script.index('release 2')
      assert_equal '= 0', lines[released], 'the release of 2 is deferred'
      assert_match(/ 2:1,2,D,1,.*,1,1,\[\],/, lines[released + 1], '2 waits for 3, its one hold')
      assert lines.drop(released).any? { |line| line.start_with?('= ASCEND 2 ') }, 'the walk goes back up into 2'
    end
  end

  # A record is freed only after every child's: 2 released while 3 lives
  # waits, and goes in the reaper's round after 3's free.
  def test_a_parents_free_waits_for_its_childs
    lines = assert_agrees([DEFERRED_FREE]).last(10)
    assert_equal ['= 0', '= 0', '= 1', '= 1', '= 0'], lines.each_slice(2).map(&:first)
    assert_match(/ 1:0,1,L,0,.*,0,2,\[\], 2:1,2,D,1,.*,1,1,\[\], 3:/, lines[1], 'released, 2 waits for 3')
    assert_match(/ 2:1,2,D,1,.*,1,0,\[\],\z/, lines[5], 'after 3, 2 waits for the next round')
    assert_match(/\A[^ ]+ 0:.* 1:0,1,L,0,.*,0,1,\[\],\z/, lines[7], 'the round frees 2')
  end

  # A chain as deep as the tree goes, every record released top down, is
  # freed bottom up, one level per round of the reaper, by no recursion.
  def test_the_deepest_chain_is_freed_one_level_per_round
    script = ['first', *(1..M::DEPTH_MAX).flat_map { |level| create(0, level - 1) }, 'close 1', 'stop 1 1 1', 'walk 0 1',
              *(['step 0'] * (4 * M::DEPTH_MAX - 2)), 'delete 0 1', *(['dstep 0'] * (2 * M::DEPTH_MAX - 1)),
              *(1..M::DEPTH_MAX).map { |id| "release #{id}" }, *(['reap'] * M::DEPTH_MAX)]
    lines = assert_agrees([script]).grep(/\A= /).last(2 * M::DEPTH_MAX)
    assert_equal [*(['= 0'] * (M::DEPTH_MAX - 1)), '= 1', *(['= 1'] * (M::DEPTH_MAX - 1)), '= 0'], lines
  end

  # A record whose attach refused it was never in the tree: from its
  # defined start it goes by the same free steps as any other, and the
  # parent it would have had counts nothing for it.
  def test_a_refused_creation_goes_by_the_free_steps
    lines = assert_agrees([REFUSED_RECORD])
    assert_equal ["= #{M::EDEAD} -", "= #{M::ESTALE} -"], lines.grep(/\A= -?\d+ -\z/)
    assert_match(/\AS 0:-1,0,L,1,.*,0,2,\[1\], 1:0,1,S,.*,0,1,\[\],\z/, lines.last)
  end

  # The poison is a real net: with a parent's record freed early, reading
  # it through its child stops the driver under AddressSanitizer.
  def test_the_poison_catches_a_read_of_a_freed_record
    name = 'parent freed before its child'
    mutant = build_driver(mutant_source(name, *MUTANTS.fetch(name)), name: 'mutant-poison',
                                                                     flags: %w[-fsanitize=address -fno-omit-frame-pointer])
    error = assert_raises(Erx::CommandError) { run_script(mutant, DELETE_ASCENT) }
    assert_includes File.read(error.message[/log: (.+)\z/, 1]), 'use-after-poison'
  end

  # The drops of one parent's holds, racing on threads as CPUs' reapers do:
  # exactly one is the last and sees the others' writes, and an ordering too
  # weak to pass them on is a reported race.
  def test_the_drops_of_a_hold_race_under_thread_sanitizer
    @runner.run([holds_race(File.join(@root, 'kernel/core/space.c'), name: 'space-holds-race')], name: 'space-holds-race',
                                                                                                 deadline: 300, env: tsan_env)
    source = File.read(File.join(@root, 'kernel/core/space.c'))
    assert_equal 1, source.scan('memory_order_acq_rel').size, 'the one ordering a drop relies on'
    weak = File.join(@directory, 'space-holds-weak.c')
    File.write(weak, source.sub('memory_order_acq_rel', 'memory_order_relaxed'))
    program = holds_race(weak, name: 'space-holds-weak')
    error = assert_raises(Erx::CommandError, 'a relaxed drop is a race') do
      @runner.run([program], name: 'space-holds-weak', deadline: 300, env: tsan_env)
    end
    assert_includes File.read(error.message[/log: (.+)\z/, 1]), 'ThreadSanitizer: data race'
  end

  # The tree is at most ERX_SPACE_DEPTH_MAX deep below the first space; a
  # creation's chain walk covers every level of it.
  def test_the_deepest_tree_and_one_level_more
    script = ['first']
    (1..M::DEPTH_MAX).each { |level| script.concat(create(0, level - 1)) }
    script << "plan 1 0 #{M::DEPTH_MAX} 0 16 #{BUDGET} #{PARENT} #{GATE}"
    script << "plan 2 #{M::DEPTH_MAX / 2} #{M::DEPTH_MAX - 1} 0 16 #{BUDGET} #{PARENT} #{GATE}"
    script << "plan 3 #{M::DEPTH_MAX} 1 0 16 #{BUDGET} #{PARENT} #{GATE}"
    lines = assert_agrees([script]).grep(/\A= /)
    assert_equal "= 0 #{M::DEPTH_MAX}", lines[-4], 'the deepest space is admitted'
    assert_equal ["= #{M::ELIMIT} 0 0", "= 0 1 #{M::DEPTH_MAX}", "= #{M::ERIGHTS} 0 0"], lines.last(3)
  end

  def test_random_creations_over_random_trees
    $stdout.puts("space_test: random creations from seed #{SEED} (set ERX_SPACE_SEED to change it)")
    rng = Random.new(SEED)
    scripts = Array.new(150) { random_script(rng, length: 60) }
    lines = assert_agrees(scripts)
    statuses = lines.grep(/\A= -?\d+ [01] \d+\z/).map { |line| Integer(line[/\A= (-?\d+)/, 1]) }.uniq
    assert_empty [0, M::EINVAL, M::ETYPE, M::ERIGHTS, M::ESTALE] - statuses, 'every plan outcome is reached'
  end

  def test_seeded_failures_are_caught
    rng = Random.new(SEED + 7)
    scripts = LIFECYCLE_EVENTS.repeated_permutation(3).map { |events| LIFECYCLE_BASE + events.flatten } +
              Array.new(40) { random_script(rng, length: 60) } +
              [['first', *(1..M::DEPTH_MAX).flat_map { |level| create(0, level - 1) },
                "plan 1 0 #{M::DEPTH_MAX} 0 16 #{BUDGET} #{PARENT} #{GATE}"],
               ['first', *create(0, 0), *create(1, 1), *create(2, 1), 'close 1', 'stop 1 1 1', 'walk 0 1',
                *(['step 0'] * 12), 'delete 0 1', *(['dstep 0'] * 5)],
               [*PINNED_TREE, *DESTROY_P, 'admit 3 3', 'ready 3', 'close 3'],
               RECORDS_NOBODY_TAKES, RECEIVER_DIED, LATE_POSTS, PARENT_WALK_FIRST, OWN_WALK_FIRST,
               ['first', "plan 0 0 self 1 16 #{BUDGET} #{PARENT} #{GATE}", 'attach 0',
                "plan 1 1 self 1 16 #{BUDGET_NO_CODE} #{PARENT} #{GATE}",
                "plan 2 0 1 0 16 #{BUDGET} #{PARENT} #{GATE}", 'attach 2',
                "plan 3 2 0 0 16 #{BUDGET} #{PARENT} #{GATE}"],
               *DEAD_PARENTS.keys, DELETE_ASCENT, STOP_ASCENT, DEFERRED_FREE, REFUSED_RECORD]
    expected = scripts.map { |script| predict(script) }
    # The core itself agrees, so a mutant's error is the mutant's.
    assert_equal expected.flatten, run_script(driver, scripts.flatten)
    MUTANTS.each do |name, (original, replacement)|
      mutant = build_driver(mutant_source(name, original, replacement), name: "mutant-#{name.downcase.tr(' ', '-')}",
                                                                       flags: [])
      assert mutant_caught?(mutant, scripts.flatten, expected.flatten), "seeded failure not caught: #{name}"
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')
  def tsan_env = Erx::SanitizerEnvironment.call(compiler: compiler)

  # The capability core, which the space core links for its rights, with
  # the cores it calls and their host's effects; host handles index the
  # object store's test store.
  def cap_core_sources = %w[kernel/core/cap.c kernel/core/object.c kernel/core/budget.c test/fixtures/host_effects.c]
                         .map { |path| File.join(@root, path) }

  def build_driver(core, name:, flags:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *flags, '-DERX_HOST', *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'),
                 '-I', Erx::Generated.path('kernel/generated', root: @root), core, *cap_core_sources,
                 File.join(@root, 'test/fixtures/space_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def holds_race(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 '-fsanitize=thread', '-fno-omit-frame-pointer', '-pthread', '-DERX_HOST',
                 *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'),
                 '-I', Erx::Generated.path('kernel/generated', root: @root), core, *cap_core_sources,
                 File.join(@root, 'test/fixtures/space_holds_race.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def mutant_source(name, original, replacement)
    source = File.read(File.join(@root, 'kernel/core/space.c'))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
    path = File.join(@directory, "space-mutant-#{name.downcase.tr(' ', '-')}.c")
    File.write(path, source.sub(original, replacement))
    path
  end

  def run_script(program, script)
    input = File.join(@directory, "script-#{script.hash.abs}.txt")
    File.write(input, script.map { |line| "#{line}\n" }.join)
    record = @runner.run([program, input], name: 'space-driver', deadline: 300)
    File.read(record.fetch('log')).lines.map(&:chomp).grep(/\A[=S] /)
  end

  # A mutant is caught when its driver prints other lines than the model
  # predicts, or stops on a tree the driver refuses to go on with.
  def mutant_caught?(mutant, script, expected)
    run_script(mutant, script) != expected
  rescue Erx::CommandError
    true
  end

  def predict(script)
    model = SpaceModel.new
    script.flat_map { |line| model.call(line) }
  end

  # Runs every script in one driver process (each starts with first) and
  # compares each line with the model's; returns the driver's lines.
  def assert_agrees(scripts)
    expected = scripts.flat_map { |script| predict(script) }
    actual = run_script(driver, scripts.flatten)
    mismatch = expected.each_index.find { |index| expected[index] != actual[index] }
    assert_nil mismatch, mismatch && "line #{mismatch}:\n  model:  #{expected[mismatch]}\n  driver: #{actual[mismatch]}"
    assert_equal expected.size, actual.size
    actual
  end

  # An actor of an interleaving: given the model, its next command, or nil
  # when it has nothing more to do.
  def once_actor(command)
    ->(_model, history) { history.include?(command) ? nil : command }
  end

  # Releases the first space that may be released: deleting, released
  # once, counted by no unfinished walk, and not the root of a destroy in
  # callers (its walk's number to its root) that has yet to finish its
  # deletion walk, since a destroy counts its root for its whole call.
  def release_actor(callers:)
    lambda do |model, history|
      busy = callers.reject { |walk, root| history.include?("delete #{walk} #{root}") && model.delete_done?(walk) }.values
      (model.releasable - busy).first&.then { |id| "release #{id}" }
    end
  end

  # A round of the reaper while a record waits on its queue.
  def reap_actor
    ->(model, _history) { model.due.empty? ? nil : 'reap' }
  end

  # A stopper: stops root and walks it to the end.
  def stop_walk_actor(walk:, root:, status:)
    walker(walk:, root:, setup: ["stop #{root} #{status} #{status}"], delete: false)
  end

  # A destroy: closes root, stops it and makes its two walks. It goes on after
  # a close that says ESTALE, where the design's stops: a superset of the
  # schedules, since its begin then says DONE.
  def destroy_actor(walk:, root:, status:)
    walker(walk:, root:, setup: ["close #{root}", "stop #{root} #{status} #{status}"], delete: true)
  end

  def walker(walk:, root:, setup:, delete:)
    lambda do |model, history|
      pending = setup.find { |line| !history.include?(line) }
      next pending if pending
      next "walk #{walk} #{root}" unless history.include?("walk #{walk} #{root}")
      next "step #{walk}" unless model.stop_done?(walk)
      next nil unless delete
      next "delete #{walk} #{root}" unless history.include?("delete #{walk} #{root}")

      model.delete_done?(walk) ? nil : "dstep #{walk}"
    end
  end

  # Every reachable state of the actors interleaved after base, and every
  # move of every actor from each: a breadth-first search over the model
  # that keeps the first path to each distinct state (the tree, the walks
  # and what each actor does next) and returns one script per move, that
  # path followed by the move, so the driver takes every transition the
  # model does. A state in which every actor in finished is done is
  # yielded; an actor left out of finished may halt after any command.
  # observe, when given, sees every distinct state.
  def explore(base, actors, finished:, observe: nil)
    start = SpaceModel.new
    base.each { |line| start.call(line) }
    seen = {}
    queue = [[start, []]]
    scripts = []
    until queue.empty?
      model, history = queue.shift
      moves = actors.filter_map do |name, actor|
        command = actor.call(model, history)
        command && [name, command]
      end
      key = [model.state_line, model.stop_walks.transform_values { |walk| walk.to_h.except(:drop) },
             model.delete_walks.transform_values { |walk| walk.to_h.except(:drop) }, model.due, model.exit_states, moves]
      next if seen.key?(key)

      seen[key] = true
      observe&.call(model)
      yield model if block_given? && finished.none? { |name| moves.any? { |moving, _| moving == name } }
      moves.each do |_, command|
        following = model.dup
        following.call(command)
        scripts << (base + history + [command])
        queue << [following, history + [command]]
      end
      raise Erx::Error, 'interleavings exceed their bound' if scripts.size > EXPLORE_BOUND
    end
    $stdout.puts("space_test: #{seen.size} states, #{scripts.size} transitions explored")
    scripts
  end

  def random_script(rng, length:)
    model = SpaceModel.new
    script = ['first']
    model.call('first')
    length.times do
      command = random_command(model, rng)
      model.call(command)
      script << command
    end
    script
  end

  def random_command(model, rng)
    count = model.spaces.size
    target = rng.rand(count)
    case rng.rand(10)
    when 0..4
      creator = rng.rand(count)
      parent = rng.rand(4).zero? ? 'self' : rng.rand(count)
      flags = rng.rand(6).zero? ? rng.rand(4) : 0
      limit = [16, 16, 16, 1, M::CAPS_MAX + 1].sample(random: rng)
      budget = [BUDGET, BUDGET, BUDGET_NO_CODE, "0,6,#{ALL}", "#{M::ESTALE},1,#{ALL}", '0,1,2000'].sample(random: rng)
      parent_cap = [PARENT, PARENT, PARENT, '0,2,8', "0,6,#{ALL}"].sample(random: rng)
      gate = [GATE, GATE, GATE, "0,6,#{M.mask(:call).to_s(16)}", "0,5,#{ALL}"].sample(random: rng)
      "plan 0 #{creator} #{parent} #{flags} #{limit} #{budget} #{parent_cap} #{gate}"
    when 5 then 'attach 0'
    when 6 then "stop #{target} #{rng.rand(9)} #{rng.rand(9)}"
    when 7 then "close #{target}"
    when 8 then "thread #{target}"
    else "admit #{target} #{rng.rand(1..4)}"
    end
  end
end
