# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/generated_abi'

# An independent model of the space core, judged against it through
# test/fixtures/space_driver.c. It keeps the tree as the design states it
# (docs/design-kernel.md, "Creating spaces"): each space's fixed parent,
# depth, flags, limit, fault gate and label; its run state (live, stopped,
# walked, deleting) and whether it is closed; its parent's list of
# children in order; and the driver's stand-ins, each space's threads as
# kill flags, its table's emptied flag, its exit record and its gate's
# count of dropped records. The walks follow the design's
# pseudo-code step for step:
#
#   stop walk, from r, which the caller has stopped
#     if s has a thread with no kill posted:  post the kills of a part
#     else if c exists and c is not walked:   stop c unless stopped; s = c
#     else:                                   mark s walked, moving it to
#                                             the end of its parent's list;
#                                             if s is r, done; else s = parent
#
#   deletion walk, from r, which is closed and whose stop walk is done
#     if c exists:     begin deleting c, which closes and unlinks c; s = c
#     else if s is r:  done
#     else:            s = the parent of s
#
# A space's record is freed only after every child's record: each space
# holds one for each child whose record is not freed and one for itself
# until it is released, and only the drop to zero frees it. A walk counts
# its root and its held space, the last space it descended into, and
# nothing else; the records between them live by that rule alone. Each
# step names the reference it ended, the space held before. A
# free that drops a parent's last hold queues the parent for the
# reaper's next round.
#
# The core splits the stop of c from the descent (it stops a live cursor
# at its next step, under its own lock) and the mark from the decision
# (FINISH, then the finish under the parent's lock); the model makes the
# same split so it predicts each line. After every command it checks the
# tree's invariants itself (check!), so agreement carries them to the core.
class SpaceModel
  CODEC = Erx::ABI::Generated::CODEC

  def self.constant(name) = CODEC.constant(name)

  OK = 0
  EINVAL = constant('einval')
  ESTALE = constant('estale')
  ETYPE = constant('etype')
  ERIGHTS = constant('erights')
  ELIMIT = constant('elimit')
  EDEAD = constant('edead')
  DEPTH_MAX = constant('space_depth_max')
  JIT = constant('space_jit')
  CAPS_MAX = constant('caps_max')
  EXIT_PARENT = constant('exit_parent')
  EXIT_RELEASED = constant('exit_released')
  OBJECT_BASE = 100
  FIRST_LIMIT = 64

  RIGHT_NAMES = %w[dup give destroy inspect read map write exec jit phys supply child code alloc spaces carve
                   system threads caps stop control configure attach signal call serve trigger bind ack power
                   trace entropy].freeze
  RIGHTS = RIGHT_NAMES.each_with_index.to_h { |name, bit| [name.to_sym, 1 << bit] }.freeze

  def self.mask(*names) = names.sum { |name| RIGHTS.fetch(name) }

  BUDGET = 1
  SPACE = 2
  GATE = 6
  # The rights the driver's lookups start from: a carved budget's, a new
  # space's and a new gate's defaults, as the design's tables give them.
  DEFAULTS = {
    BUDGET => mask(:alloc, :spaces, :code, :carve, :inspect, :dup, :give, :destroy),
    SPACE => mask(:map, :threads, :caps, :stop, :inspect, :dup, :give, :destroy)
  }.freeze
  GATE_DEFAULT = mask(:call, :serve, :configure, :inspect, :dup, :give, :destroy)

  Source = Data.define(:status, :type, :rights, :object)
  Space = Struct.new(:parent, :depth, :run, :closed, :flags, :cap_limit, :gate, :label, :status, :stopper,
                     :emptied, :children, :threads, :holds, :released, :freed, :exit, :dead, keyword_init: true)
  Plan = Data.define(:parent, :depth, :flags, :cap_limit, :gate, :label)
  StopWalk = Struct.new(:root, :cursor, :finishing, :held, :drop, keyword_init: true)
  DeleteWalk = Struct.new(:root, :cursor, :held, :drop, keyword_init: true)

  # Raised by check! when the model's own tree breaks an invariant.
  Broken = Class.new(StandardError)

  attr_reader :spaces, :stop_walks, :delete_walks, :due

  def initialize
    reset
  end

  def initialize_copy(other)
    super
    @spaces = other.spaces.map { |space| space.dup.tap { |s| s.children = s.children.dup; s.threads = s.threads.dup } }
    @plans = other.instance_variable_get(:@plans).dup
    @stop_walks = other.stop_walks.transform_values(&:dup)
    @delete_walks = other.delete_walks.transform_values(&:dup)
    @due = other.instance_variable_get(:@due).dup
    @dropped = other.instance_variable_get(:@dropped)
  end

  # Runs one driver command and returns the lines the driver prints.
  def call(line)
    words = line.split
    result = dispatch(words.first, words.drop(1))
    check!
    ["= #{result}", state_line]
  end

  def stop_done?(walk) = !@stop_walks.key?(walk) || @stop_walks.fetch(walk).cursor.nil?
  def delete_done?(walk) = !@delete_walks.key?(walk) || @delete_walks.fetch(walk).cursor.nil?

  # The spaces whose record may be released: deleting, with no exit record
  # waiting, released once, counted by no unfinished walk and named by no
  # unspent plan.
  def releasable = @spaces.each_index.select { |id| releasable?(id) }

  # The ids of the spaces at or below id, by the parent chain.
  def subtree(id) = @spaces.each_index.select { |other| at_or_below?(other, id) }

  # Each record's state and the gate's count, which the state line leaves out.
  def exit_states = [@spaces.map(&:exit), @dropped]

  def state_line
    runs = { L: 'L', S: 'S', W: 'W', D: 'D' }
    entries = @spaces.each_with_index.reject { |space, _| space.freed }.map do |space, id|
      status, stopper = space.run == :L ? [0, 0] : [space.status, space.stopper]
      "#{id}:#{space.parent || -1},#{space.depth},#{runs.fetch(space.run)},#{space.closed ? 1 : 0}," \
        "#{space.flags},#{space.cap_limit},#{space.gate},#{space.label.to_s(16)},#{status},#{stopper}," \
        "#{space.emptied ? 1 : 0},#{space.holds},[#{space.children.join(' ')}]," \
        "#{space.threads.map { |k| k ? 'k' : 'u' }.join}"
    end
    "S #{entries.join(' ')}"
  end

  private

  def reset
    @spaces = [Space.new(parent: nil, depth: 0, run: :L, closed: false, flags: 0, cap_limit: FIRST_LIMIT, gate: 0,
                         label: 0, status: 0, stopper: 0, emptied: false, children: [], threads: [], holds: 1, exit: :N)]
    @plans = {}
    @due = []
    @dropped = 0
    @stop_walks = {}
    @delete_walks = {}
    OK
  end

  def dispatch(command, args)
    case [command, args.size]
    in ['first', 0] then reset
    in ['plan', 8] then plan(*args)
    in ['attach', 1] then attach(Integer(args[0]))
    in ['stop', 3] then stop(Integer(args[0]), Integer(args[1]), Integer(args[2])) ? 1 : 0
    in ['close', 1] then close(Integer(args[0]))
    in ['admit', 2] then admit(Integer(args[0]), Integer(args[1]))
    in ['thread', 1] then thread(Integer(args[0]))
    in ['walk', 2] then walk(Integer(args[0]), Integer(args[1]))
    in ['step', 1] then step(Integer(args[0]))
    in ['delete', 2] then delete(Integer(args[0]), Integer(args[1]))
    in ['dstep', 1] then dstep(Integer(args[0]))
    in ['detach', 2] then detach(Integer(args[0]), Integer(args[1]))
    in ['release', 1] then release(Integer(args[0]))
    in ['reap', 0] then reap
    in ['post', 1] then post(Integer(args[0]))
    in ['place', 1] then place(Integer(args[0]))
    in ['dead', 1] then dead(Integer(args[0]))
    in ['take', 1] then take(Integer(args[0]))
    in ['exit', 1] then exit_line(Integer(args[0]))
    in ['ready', 1] then ready?(Integer(args[0])) ? 1 : 0
    in ['state', 0] then nil
    end
  end

  def source(text)
    status, type, rights, object = text.split(',')
    type = Integer(type)
    Source.new(status: Integer(status), type: type,
               rights: DEFAULTS.fetch(type, GATE_DEFAULT) & Integer(rights, 16), object: Integer(object || '0'))
  end

  def plan(slot, self_text, parent_text, flags_text, limit_text, *sources)
    slot = Integer(slot)
    self_id = Integer(self_text)
    parent_id = parent_text == 'self' ? self_id : Integer(parent_text)
    budget, parent_cap, fault = sources.map { |text| source(text) }
    parent_cap = parent_cap.with(object: OBJECT_BASE + parent_id) if parent_cap.object.zero?
    request = { self_id:, parent_id:, parent_self: parent_text == 'self', flags: Integer(flags_text),
                cap_limit: Integer(limit_text), budget:, parent_cap:, fault: }
    status = plan_status(request)
    @plans[slot] = status == OK ? new_plan(request, slot) : nil
    "#{status} #{status == OK ? 1 : 0} #{status == OK ? @plans[slot].depth : 0}"
  end

  def plan_status(request)
    flags = request.fetch(:flags)
    limit = request.fetch(:cap_limit)
    return EINVAL if flags & ~JIT != 0 || limit < 2 || limit > CAPS_MAX

    budget = request.fetch(:budget)
    refusal = lookup_refusal(budget, BUDGET, mask(:alloc, :spaces))
    return refusal if refusal

    unless request.fetch(:parent_self)
      parent_cap = request.fetch(:parent_cap)
      refusal = lookup_refusal(parent_cap, SPACE, mask(:caps))
      return refusal if refusal
      return EINVAL if parent_cap.object != OBJECT_BASE + request.fetch(:parent_id)
    end
    refusal = lookup_refusal(request.fetch(:fault), GATE, mask(:serve))
    return refusal if refusal

    self_space = @spaces.fetch(request.fetch(:self_id))
    jit_allowed = budget.rights & mask(:code) != 0 || self_space.flags & JIT != 0
    return ERIGHTS if flags & JIT != 0 && !jit_allowed
    parent = @spaces.fetch(request.fetch(:parent_id))
    return ESTALE if parent.closed
    return EDEAD unless parent.run == :L
    return ERIGHTS unless at_or_below?(request.fetch(:parent_id), request.fetch(:self_id))
    return ELIMIT if @spaces.fetch(request.fetch(:parent_id)).depth >= DEPTH_MAX

    OK
  end

  def mask(*names) = self.class.mask(*names)

  def lookup_refusal(source, type, required)
    return source.status unless source.status == OK
    return ETYPE unless source.type == type
    return ERIGHTS unless source.rights & required == required

    nil
  end

  def new_plan(request, slot)
    Plan.new(parent: request.fetch(:parent_id), depth: @spaces.fetch(request.fetch(:parent_id)).depth + 1,
             flags: request.fetch(:flags), cap_limit: request.fetch(:cap_limit),
             gate: request.fetch(:fault).object, label: 0x1000 + slot)
  end

  def at_or_below?(id, ancestor)
    loop do
      return true if id == ancestor
      return false if id.nil?

      id = @spaces.fetch(id).parent
    end
  end

  def attach(slot)
    plan = @plans.delete(slot)
    return "#{EINVAL} -" if plan.nil?

    parent = @spaces.fetch(plan.parent)
    return "#{ESTALE} -" if parent.closed
    return "#{EDEAD} -" unless parent.run == :L

    @spaces << Space.new(parent: plan.parent, depth: plan.depth, run: :L, closed: false, flags: plan.flags,
                         cap_limit: plan.cap_limit, gate: plan.gate, label: plan.label, status: 0, stopper: 0,
                         emptied: false, children: [], threads: [], holds: 1, exit: :N)
    parent.children.unshift(@spaces.size - 1)
    parent.holds += 1
    "#{OK} #{@spaces.size - 1}"
  end

  def stop(id, status, stopper)
    space = @spaces.fetch(id)
    return false unless space.run == :L

    space.run = :S
    space.status = status
    space.stopper = stopper
    true
  end

  def close(id)
    space = @spaces.fetch(id)
    return ESTALE if space.closed

    space.closed = true
    OK
  end

  def admit(id, what)
    space = @spaces.fetch(id)
    return EINVAL unless [1, 2, 3].include?(what)
    return ESTALE if space.closed
    return EDEAD if what != 3 && space.run != :L

    OK
  end

  def thread(id)
    status = admit(id, 2)
    @spaces.fetch(id).threads << false if status == OK
    status
  end

  def walk(walk, root)
    return EINVAL if @spaces.fetch(root).run == :L

    @stop_walks[walk] = StopWalk.new(root:, cursor: root, finishing: false, held: nil)
    OK
  end

  def step(walk)
    state = @stop_walks.fetch(walk) { StopWalk.new(root: nil, cursor: nil, finishing: false, held: nil) }
    @stop_walks[walk] = state
    state.drop = nil
    walk_line(state.finishing ? finish(state) : stop_step(state), state)
  end

  def walk_line(action, state)
    "#{action} #{id_text(state.cursor)} #{id_text(state.held)} #{id_text(state.drop)}"
  end

  def stop_step(state)
    return 'DONE' if state.cursor.nil?

    space = @spaces.fetch(state.cursor)
    if space.run == :L
      stop(state.cursor, EXIT_PARENT, @spaces.fetch(space.parent).stopper)
      return 'STOPPED'
    end
    if space.threads.first == false
      space.threads.shift
      space.threads << true
      return 'KILL'
    end
    child = space.children.first
    if child && %i[L S].include?(@spaces.fetch(child).run)
      state.cursor = child
      state.drop = state.held
      state.held = child
      return 'DESCEND'
    end
    state.finishing = true
    'FINISH'
  end

  def finish(state)
    state.finishing = false
    space = @spaces.fetch(state.cursor)
    if space.run == :S
      space.run = :W
      if space.parent
        siblings = @spaces.fetch(space.parent).children
        siblings.delete(state.cursor)
        siblings << state.cursor
      end
    end
    if state.cursor == state.root
      state.cursor = nil
      state.drop = state.held
      state.held = nil
      return 'DONE'
    end
    state.cursor = space.parent
    'ASCEND'
  end

  def id_text(id) = id.nil? ? -1 : id

  def delete(walk, root)
    space = @spaces.fetch(root)
    return "#{EINVAL} 0" unless space.closed && %i[W D].include?(space.run)

    @delete_walks[walk] = DeleteWalk.new(root:, cursor: nil, held: nil)
    return "#{OK} 3" if space.run == :D

    begin_deletion(root)
    @delete_walks[walk].cursor = root
    "#{OK} 1"
  end

  def begin_deletion(id)
    space = @spaces.fetch(id)
    space.run = :D
    space.closed = true
    space.emptied = true
    drop_record(space) if space.exit == :W && !space.dead
    @spaces.fetch(space.parent).children.delete(id) if space.parent
  end

  def dstep(walk)
    state = @delete_walks.fetch(walk) { DeleteWalk.new(root: nil, cursor: nil, held: nil) }
    @delete_walks[walk] = state
    state.drop = nil
    walk_line(delete_step(state), state)
  end

  def delete_step(state)
    return 'DONE' if state.cursor.nil?

    space = @spaces.fetch(state.cursor)
    child = space.children.first
    if child
      return 'INVALID' unless @spaces.fetch(child).run == :W

      begin_deletion(child)
      state.cursor = child
      state.drop = state.held
      state.held = child
      return 'DELETE'
    end
    if state.cursor == state.root
      state.cursor = nil
      state.drop = state.held
      state.held = nil
      return 'DONE'
    end
    state.cursor = space.parent
    'ASCEND'
  end

  def detach(id, gate)
    space = @spaces.fetch(id)
    return 0 if gate.zero? || space.gate != gate

    space.gate = 0
    1
  end

  # A space's post, at most once in effect: a record goes on its way to the
  # home CPU, or is dropped and counted when the deletion began first.
  def post(id)
    space = @spaces.fetch(id)
    return "NONE #{exit_line(id)}" unless space.exit == :N
    if space.run == :D
      drop_record(space)
      return "DROP #{exit_line(id)}"
    end

    space.exit = :P
    "QUEUE #{exit_line(id)}"
  end

  # Under the gate's lock, a record just posted is placed, or one whose
  # receiver died is moved: it waits, unless the deletion has begun.
  def place(id)
    space = @spaces.fetch(id)
    if %i[P W].include?(space.exit)
      space.run == :D ? drop_record(space) : space.exit = :W
    end
    exit_line(id)
  end

  def dead(id)
    @spaces.fetch(id).dead = true
    exit_line(id)
  end

  def drop_record(space)
    space.exit = :D
    @dropped += 1
  end

  # The gate's server receives the record, when one waits.
  def take(id)
    space = @spaces.fetch(id)
    space.exit = :T if space.exit == :W
    exit_line(id)
  end

  def exit_line(id) = "#{@spaces.fetch(id).exit} #{@dropped}"

  # Nothing a party holds keeps the record: the space is closed, it is
  # deleting, and no exit record of it waits at its gate.
  def ready?(id)
    space = @spaces.fetch(id)
    space.closed && space.run == :D && space.exit != :W
  end

  # The space is otherwise ready to free: its own hold goes. Only a
  # deleting space with no record waiting, released once, counted by no unfinished walk (its root
  # and its held space) and named by no unspent plan is released; the
  # driver refuses anything else. 1 when the record is freed now.
  def release(id)
    raise Broken, "space #{id} released while in use" unless releasable?(id)

    @spaces.fetch(id).released = true
    unhold(id) ? free_record(id) : 0
  end

  # One round of the reaper: the records queued before it, each of whose
  # frees may queue its parent for the next round.
  def reap
    round = @due
    @due = []
    round.each { |id| free_record(id) }
    round.size
  end

  def releasable?(id)
    space = @spaces.fetch(id)
    counted = (@stop_walks.values + @delete_walks.values).any? { |walk| walk.cursor && [walk.root, walk.held].include?(id) } ||
              @plans.each_value.any? { |plan| plan&.parent == id }
    id != 0 && space.run == :D && !%i[W P].include?(space.exit) && !space.released && !space.freed && !counted
  end

  def unhold(id)
    space = @spaces.fetch(id)
    space.holds -= 1
    space.holds.zero?
  end

  # The record goes; the driver poisons it, so the state line leaves it
  # out and the tree keeps it for the invariants.
  def free_record(id)
    space = @spaces.fetch(id)
    space.freed = true
    @due << space.parent if space.parent && unhold(space.parent)
    1
  end

  # The tree's invariants, which hold after every command whatever the
  # interleaving: every space but the first has a parent one level up; a
  # list holds exactly the parent's children that are not deleting, the
  # walked ones last; a live space is never below a walked one; a stopped
  # space's threads and children are what the walk left; and a table is
  # emptied exactly when its space is deleting, a deleting space is closed
  # and has no record waiting. A space holds one for
  # each child whose record is not freed and one until it is released;
  # a freed record had no hold left, so its children's records went
  # before it; and no walk is on, or counts, a freed record.
  def check!
    @spaces.each_with_index do |space, id|
      if id.zero?
        raise Broken, 'the first space has a parent' if space.parent
      else
        raise Broken, "space #{id} depth" unless space.depth == @spaces.fetch(space.parent).depth + 1
      end
      listed = @spaces.each_index.select { |child| @spaces.fetch(child).parent == id && @spaces.fetch(child).run != :D }
      raise Broken, "space #{id} list #{space.children} != #{listed}" unless space.children.sort == listed
      runs = space.children.map { |child| @spaces.fetch(child).run }
      raise Broken, "space #{id} list order #{runs}" unless runs == runs.sort_by { |run| run == :W ? 1 : 0 }
      raise Broken, "space #{id} emptied flag" unless space.emptied == (space.run == :D)
      raise Broken, "space #{id} deleting but not closed" if space.run == :D && !space.closed
      raise Broken, "space #{id} deleting with a record waiting" if space.run == :D && space.exit == :W && !space.dead
      raise Broken, "space #{id} live below a walked parent" if space.run == :L && space.parent &&
                                                               %i[W D].include?(@spaces.fetch(space.parent).run)
      raise Broken, "space #{id} walked with a thread unkilled" if %i[W D].include?(space.run) &&
                                                                  !space.threads.all?
      check_holds!(space, id)
    end
    (@stop_walks.values + @delete_walks.values).each do |walk|
      [walk.root, walk.cursor, walk.held].compact.each do |at|
        raise Broken, "a walk is on freed space #{at}" if walk.cursor && @spaces.fetch(at).freed
      end
    end
    @stop_walks.each_value do |walk|
      next unless walk.cursor.nil? && walk.root

      subtree(walk.root).each do |id|
        space = @spaces.fetch(id)
        raise Broken, "walk from #{walk.root} left #{id} unwalked" unless %i[W D].include?(space.run)
      end
    end
  end

  def check_holds!(space, id)
    unfreed = @spaces.count { |child| child.parent == id && !child.freed }
    raise Broken, "space #{id} holds #{space.holds}" unless space.holds == unfreed + (space.released ? 0 : 1)
    raise Broken, "space #{id} freed before a child" if space.freed && !unfreed.zero?
    raise Broken, "space #{id} freed unreleased" if space.freed && !space.released
  end
end
