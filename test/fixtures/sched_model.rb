# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/generated_abi'

# The reference for the scheduler core: docs/design-scheduler.md's rules, on
# arrays and plain recursion, sharing nothing with kernel/sched/sched.c. It
# takes the commands test/fixtures/sched_driver.c takes and predicts every
# line the driver prints. Limits come from the ABI's generated table.
class SchedModel
  CODEC = Erx::ABI::Generated::CODEC
  URGENCY_MAX = CODEC.constant('urgency_max')
  PERIOD = CODEC.constant('period_min')..CODEC.constant('period_max')
  CPUSET_BITS = CODEC.constant('cpuset_bits')
  SLICE = CODEC.constant('slice_min_us')..CODEC.constant('slice_max_us')
  GRACE = CODEC.constant('grace_min_us')..CODEC.constant('grace_max_us')
  DEPTH_MAX = CODEC.constant('group_depth_max')
  QUOTA_NONE = CODEC.constant('quota_none')
  EINVAL = CODEC.constant('einval')
  ELIMIT = CODEC.constant('elimit')
  FLAGS_DEFINED = 0xf
  PICK_MOVES = 8
  CPUS = 4
  MACHINE = (1 << CPUS) - 1
  NO_CPU = 64
  BLOCKED = 0
  SLICE_END = 1
  YIELD = 2
  PREEMPTED = 3

  Grant = Data.define(:quota, :period, :cpuset, :mcpu, :first, :slice, :grace, :base, :ceiling, :flags, :padding) do
    def to_line = [quota, period, cpuset, mcpu, first, slice, grace, base, ceiling, flags].join(',')
  end

  Group = Struct.new(:parent, :grant)
  Member = Struct.new(:id, :group, :own_base, :affinity, :state, :left, :last, :urgency)
  Cpu = Struct.new(:queues, :running)

  # A grant as the driver's eleven numbers; every field has a usable default.
  def self.grant(quota: QUOTA_NONE, period: 10_000_000, cpuset: 0xf, mcpu: 4000, first: 0, slice: 5000, grace: 50,
                 base: 16, ceiling: 31, flags: 0, padding: 0)
    [quota, period, cpuset, mcpu, first, slice, grace, base, ceiling, flags, padding].join(' ')
  end

  def initialize
    machine(0)
  end

  # One command: the lines the driver prints for it.
  def call(line)
    name, *words = line.split
    args = words.map { |word| Integer(word) }
    [public_send(name, *args)]
  end

  def machine(cap)
    @cap = cap
    @groups = []
    @threads = []
    @cpus = Array.new(CPUS) { Cpu.new(Hash.new { |queues, level| queues[level] = [] }, nil) }
    '= 0'
  end

  def root(*words)
    grant = parse(words)
    return "= #{EINVAL}" if normalized(grant).nil? || (grant.cpuset & MACHINE).zero?

    @groups << Group.new(nil, normalized(grant))
    '= 0'
  end

  def group(parent, *words)
    grant = normalized(parse(words))
    return "= #{EINVAL}" if grant.nil?
    return "= #{ELIMIT}" if depth(fetch_group(parent)) + 1 >= DEPTH_MAX

    @groups << Group.new(fetch_group(parent), grant)
    '= 0'
  end

  def configure(id, *words)
    target = fetch_group(id)
    raw = parse(words)
    grant = normalized(raw)
    return "= #{EINVAL}" if grant.nil? || (target.parent.nil? && (raw.cpuset & MACHINE).zero?)

    target.grant = grant
    '= 0'
  end

  def normalize(*words)
    grant = normalized(parse(words))
    grant ? "= 0 #{grant.to_line}" : "= #{EINVAL}"
  end

  def thread(group_id)
    @threads << Member.new(@threads.size, fetch_group(group_id), nil, (1 << 64) - 1, :off, 0, NO_CPU, 0)
    '= 0'
  end

  def urgency(id, value)
    return "= #{EINVAL}" if value > URGENCY_MAX

    @threads.fetch(id).own_base = value
    '= 0'
  end

  def affinity(id, mask)
    @threads.fetch(id).affinity = mask
    '= 0'
  end

  def wake(cpu_id, id)
    thread = @threads.fetch(id)
    return '= 0' unless thread.state == :off

    cpu = @cpus.fetch(cpu_id)
    thread.urgency = resolve(thread)
    cpu.queues[thread.urgency] << thread
    thread.state = [:ready, cpu_id]
    "= #{must_pick?(cpu, thread.urgency) ? 1 : 0}"
  end

  # A thread's base or a ceiling above it changed: its home CPU resolves it.
  def refresh(cpu_id, id)
    thread = @threads.fetch(id)
    cpu = @cpus.fetch(cpu_id)
    return refresh_running(cpu, thread) if cpu.running == thread
    return '= 0' unless thread.state == [:ready, cpu_id]

    old = thread.urgency
    thread.urgency = resolve(thread)
    unless thread.urgency == old
      cpu.queues[old].delete(thread)
      cpu.queues[thread.urgency] << thread
    end
    "= #{must_pick?(cpu, thread.urgency) ? 1 : 0}"
  end

  def remove(cpu_id, id)
    thread = @threads.fetch(id)
    return '= 0' unless thread.state == [:ready, cpu_id]

    @cpus.fetch(cpu_id).queues.each_value { |queue| queue.delete(thread) }
    thread.state = :off
    '= 1'
  end

  def pick(cpu_id, why, ran)
    Pick.new(self, @cpus.fetch(cpu_id), cpu_id).call(why, ran)
  end

  def place(id, idle)
    thread = @threads.fetch(id)
    allowed = cpus_of(thread)
    allowed_idle = allowed & idle
    return "= #{thread.last}" if bit?(allowed_idle, thread.last)
    return "= #{lowest(allowed_idle)}" unless allowed_idle.zero?
    return "= #{thread.last}" if bit?(allowed, thread.last)

    "= #{lowest(allowed)}"
  end

  def state
    (['S'] + @groups.each_with_index.map { |group, index| group_line(group, index) } +
      @threads.map { |thread| thread_line(thread) } +
      @cpus.each_with_index.map { |cpu, index| cpu_line(cpu, index) }).join(' ')
  end

  # What a pick reads of the machine.
  def resolve(thread)
    [thread.own_base || thread.group.grant.base, ceiling(thread.group)].min
  end

  def cpus_of(thread)
    effective = cpuset(thread.group)
    allowed = effective & thread.affinity
    allowed.zero? ? effective : allowed
  end

  def slice_ns(thread) = thread.group.grant.slice * 1000

  # One pick: its own record of how many it moved.
  class Pick
    def initialize(model, cpu, cpu_id)
      @model = model
      @cpu = cpu
      @cpu_id = cpu_id
      @leaving = []
      @moves = 0
    end

    def call(why, ran)
      give_up(@cpu.running, why, ran) if @cpu.running
      until (level = @cpu.queues.select { |_, queue| queue.any? }.keys.max).nil?
        thread = @cpu.queues[level].first
        return dispatch(level, thread) if allowed?(thread)
        return report(nil, again: true) if @moves == PICK_MOVES

        @moves += 1
        @cpu.queues[level].shift
        leave(thread)
      end
      report(nil, again: false)
    end

    private

    def allowed?(thread) = @model.cpus_of(thread)[@cpu_id] == 1

    def give_up(thread, why, ran)
      thread.left = [thread.left - ran, 0].max
      @cpu.running = nil
      thread.left = 0 if why == SLICE_END
      if why == BLOCKED
        thread.state = :off
        return
      end
      unless allowed?(thread)
        @moves += 1
        return leave(thread)
      end

      thread.urgency = @model.resolve(thread)
      thread.state = [:ready, @cpu_id]
      if why == PREEMPTED && thread.left.positive?
        @cpu.queues[thread.urgency].unshift(thread)
      else
        @cpu.queues[thread.urgency].push(thread)
      end
    end

    def leave(thread)
      thread.state = :off
      @leaving << thread.id
    end

    def dispatch(level, thread)
      @cpu.queues[level].shift
      whole = @model.slice_ns(thread)
      thread.left = thread.left.zero? ? whole : [thread.left, whole].min
      thread.state = :running
      thread.last = @cpu_id
      @cpu.running = thread
      report(thread, urgency: thread.urgency, again: false)
    end

    def report(thread, again:, urgency: 0)
      run = thread ? thread.id : '-'
      "= run=#{run} urgency=#{urgency} slice=#{thread ? thread.left : 0} again=#{again ? 1 : 0} " \
        "leaving=#{@leaving.join('+')}"
    end
  end

  private

  def parse(words) = Grant.new(*words)
  def must_pick?(cpu, urgency) = cpu.running.nil? || urgency > cpu.running.urgency

  def refresh_running(cpu, thread)
    thread.urgency = resolve(thread)
    highest = cpu.queues.select { |_, queue| queue.any? }.keys.max
    "= #{!highest.nil? && highest > thread.urgency ? 1 : 0}"
  end

  def fetch_group(id) = @groups.fetch(id)
  def depth(group) = group.parent ? depth(group.parent) + 1 : 0
  def bit?(mask, cpu) = cpu < 64 && mask[cpu] == 1
  def lowest(mask) = (mask & -mask).bit_length - 1
  def ceiling(group) = [group.grant.ceiling, *(group.parent && ceiling(group.parent))].min

  def cpuset(group)
    return group.grant.cpuset & MACHINE unless group.parent

    parent = cpuset(group.parent)
    narrowed = parent & group.grant.cpuset
    narrowed.zero? ? parent : narrowed
  end

  # nil for a grant the kernel refuses.
  def normalized(grant)
    return nil if [grant.base, grant.ceiling].max > URGENCY_MAX
    return nil if (grant.flags & ~FLAGS_DEFINED) != 0 || grant.padding != 0

    period = grant.period.clamp(PERIOD)
    quota = grant.quota == QUOTA_NONE ? QUOTA_NONE : [grant.quota, period * CPUSET_BITS].min
    grant.with(quota: quota, period: period, slice: grant.slice.clamp(SLICE), grace: grant.grace.clamp(GRACE),
               base: [grant.base, grant.ceiling].min, flags: grant.flags & @cap)
  end

  def capacity(group)
    grant = group.grant
    cpus = cpuset(group).digits(2).sum
    limits = [grant.mcpu, cpus * 1000]
    limits << grant.quota * 1000 / grant.period unless grant.quota == QUOTA_NONE
    [limits.min, grant.first % cpus]
  end

  def group_line(group, index)
    mcpu, first = capacity(group)
    "g#{index}:#{ceiling(group)},#{[group.grant.base, ceiling(group)].min},#{cpuset(group)}," \
      "#{group.grant.slice * 1000},#{mcpu},#{first}/#{group.grant.to_line}"
  end

  def thread_line(thread)
    letter = case thread.state
             when :off then 'o'
             when :running then 'R'
             else 'r'
             end
    home = case thread.state
           when :off then NO_CPU
           when :running then thread.last
           else thread.state.last
           end
    "t#{thread.id}:#{resolve(thread)},#{cpus_of(thread)},#{letter},#{thread.left},#{thread.last},#{home},#{slice_ns(thread)},#{thread.urgency}"
  end

  def cpu_line(cpu, index)
    levels = cpu.queues.select { |_, queue| queue.any? }.sort.map do |level, queue|
      ";#{level}=#{queue.map(&:id).join('+')}"
    end
    ready = cpu.queues.select { |_, queue| queue.any? }.keys.sum { |level| 1 << level }
    "c#{index}:#{cpu.running ? cpu.running.id : '-'},#{ready.to_s(16)}#{levels.join}"
  end
end
