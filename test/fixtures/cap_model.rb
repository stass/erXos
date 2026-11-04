# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/generated/abi'

# An independent model of the capability core (kernel/core/cap.c), written
# from docs/design-kernel.md ("Objects and capabilities", "Rights",
# "Passing capabilities", "Sequence-counted records") and not from the C.
# Its rights tables are the design's own tables, typed in here, so they
# judge the ABI file's declarations too. A model value is immutable; each
# operation returns the next model and what the driver must print.
module CapModel
  CODEC = Erx::ABI::Generated::CODEC

  def self.constant(name) = CODEC.constant(name)

  OK = constant('ok')
  EINVAL = constant('einval')
  ESTALE = constant('estale')
  ETYPE = constant('etype')
  ERIGHTS = constant('erights')
  ELIMIT = constant('elimit')
  EDEAD = constant('edead')
  EBUSY = constant('ebusy')

  SLOT_BITS = 24
  GENERATION_LIMIT = (1 << 40) - 1
  TERMINAL = (1 << 64) - 1
  FREE_MAX = TERMINAL - 5
  PAGE = 64
  CAPS_MAX = 1 << 20
  MSG_CAPS = 4
  DRIVER_PAGES = 4
  COPY = 1
  MOVE = 2

  RIGHT_NAMES = %w[dup give destroy inspect read map write exec jit phys supply child code alloc spaces carve
                   system threads caps stop control configure attach signal call serve trigger bind ack power
                   trace entropy].freeze
  RIGHTS = RIGHT_NAMES.each_with_index.to_h { |name, bit| [name.to_sym, 1 << bit] }.freeze

  def self.mask(*names) = names.sum { |name| RIGHTS.fetch(name) }

  # The design's table of types: rights each can carry, and its pass set.
  TYPES = {
    budget: [1, mask(:alloc, :spaces, :code, :carve, :inspect, :dup, :give, :destroy), 0],
    space: [2, mask(:map, :threads, :caps, :stop, :inspect, :dup, :give, :destroy), 0],
    thread: [3, mask(:control, :configure, :inspect, :dup, :give, :destroy), 0],
    group: [4, mask(:configure, :attach, :signal, :inspect, :dup, :give, :destroy), 0],
    memory: [5, mask(:read, :write, :exec, :map, :jit, :phys, :supply, :child, :carve, :system, :inspect, :dup,
                     :give, :destroy),
             mask(:read, :write, :map, :child, :inspect, :dup, :give)],
    gate: [6, mask(:call, :serve, :configure, :inspect, :dup, :give, :destroy), mask(:call, :serve, :inspect, :dup, :give)],
    irq: [7, mask(:trigger, :bind, :ack, :configure, :inspect, :dup, :give, :destroy), mask(:trigger, :inspect, :dup, :give)],
    resource: [8, mask(:carve, :power, :trace, :entropy, :inspect, :dup, :give), 0],
    dma: [9, mask(:map, :bind, :inspect, :dup, :give, :destroy), 0]
  }.freeze
  TYPE_NUMBER = TYPES.transform_values(&:first).freeze
  CARRY = TYPES.values.to_h { |number, carry, _pass| [number, carry] }.freeze
  PASS = TYPES.values.to_h { |number, _carry, pass| [number, pass] }.freeze

  # The design's rows of created rights, by creation kind.
  SHARED = mask(:read, :write, :map, :supply, :child, :inspect, :dup, :give, :destroy)
  PHYSICAL = mask(:read, :write, :map, :child, :inspect, :dup, :give, :destroy)
  PAGED = mask(:read, :map, :supply, :child, :inspect, :dup, :give, :destroy)
  MACHINE = mask(:read, :map, :inspect, :dup, :give)
  LINE = mask(:trigger, :bind, :ack, :configure, :inspect, :dup, :give, :destroy)
  KINDS = {
    'root_budget' => mask(:alloc, :spaces, :code, :carve, :inspect, :dup, :give),
    'carved_budget' => mask(:alloc, :spaces, :code, :carve, :inspect, :dup, :give, :destroy),
    'new_space' => TYPES.fetch(:space)[1],
    'new_thread' => TYPES.fetch(:thread)[1],
    'new_group' => TYPES.fetch(:group)[1],
    'new_gate' => TYPES.fetch(:gate)[1],
    'shared_memory' => SHARED,
    'physical_memory' => PHYSICAL,
    'contiguous_memory' => PHYSICAL | mask(:phys),
    'jit_memory' => mask(:read, :write, :exec, :map, :jit, :inspect, :destroy),
    'paged_memory' => PAGED,
    'paged_code_memory' => PAGED | mask(:exec),
    'cow_child' => mask(:read, :write, :map, :inspect, :dup, :give, :destroy),
    'boot_image' => mask(:read, :exec, :map, :child, :carve, :system, :inspect, :dup, :give),
    'image_slice' => mask(:read, :exec, :map, :child, :inspect, :dup, :give, :destroy),
    'time_page' => mask(:read, :write, :map, :inspect, :dup, :give),
    'machine_page' => MACHINE,
    'previous_crash' => MACHINE | mask(:destroy),
    'device_secret' => mask(:read, :map, :inspect),
    'software_irq' => mask(:trigger, :bind, :inspect, :dup, :give, :destroy),
    'line_irq' => LINE,
    'msi_irq' => LINE,
    'root_resource' => mask(:carve, :power, :trace, :entropy, :inspect, :dup, :give),
    'carved_resource' => mask(:carve, :inspect, :dup, :give),
    'dma_window' => TYPES.fetch(:dma)[1],
    'reserved_space' => mask(:map, :threads, :caps, :stop),
    'reserved_thread' => mask(:configure)
  }.freeze

  Slot = Data.define(:state, :generation, :seq, :object, :type, :rights) do
    def live? = state == :live
    def dump(index) = format('slot %x %x %x %x %x %x %x', index, STATES.index(state), generation, seq, object, type, rights)
  end
  STATES = %i[free reserved live retired].freeze
  FRESH = Slot.new(state: :free, generation: 0, seq: 0, object: 0, type: 0, rights: 0)

  # One table: its slots below capacity, its FIFO free list, its one
  # reservation and the emptied flag.
  Table = Data.define(:limit, :slots, :free, :held, :emptied) do
    def capacity = slots.size

    def dump
      [*slots.each_with_index.map { |slot, index| slot.dump(index) },
       ['free', format('%x', free.size), *free.map { |index| format('%x', index) }].join(' '),
       ['held', format('%x', held.size), *held.map { |index| format('%x', index) }].join(' ')]
    end

    def with_slot(index, slot) = with(slots: slots.dup.tap { |copy| copy[index] = slot }.freeze)
  end

  module_function

  def value(slot, generation) = (generation << SLOT_BITS) | slot
  def decode(value) = [value & ((1 << SLOT_BITS) - 1), value >> SLOT_BITS]

  def table(limit)
    pages = (limit + PAGE - 1) / PAGE
    return [nil, EINVAL] unless limit.between?(2, CAPS_MAX) && pages <= DRIVER_PAGES

    [Table.new(limit: limit, slots: [].freeze, free: [].freeze, held: [].freeze, emptied: false), OK]
  end

  # A page's slots, slot 0 retired for good; the pages a want needs.
  def grow(table, want)
    capacity = table.capacity
    have = table.free.size
    pages = 0
    while have < want
      return [table, ELIMIT, 0] if capacity >= table.limit

      stop = [capacity + PAGE, table.limit].min
      have += stop - capacity - (capacity.zero? ? 1 : 0)
      capacity = stop
      pages += 1
    end
    slots = table.slots.dup
    free = table.free.dup
    (table.capacity...capacity).each do |index|
      slots << (index.zero? ? FRESH.with(state: :retired, seq: TERMINAL) : FRESH)
      free << index unless index.zero?
    end
    # Slots of a partial last page beyond the limit are never reachable.
    [table.with(slots: slots.freeze, free: free.freeze), OK, pages]
  end

  def seed(table, index, generation, seq) = table.with_slot(index, table.slots.fetch(index).with(generation: generation, seq: seq))

  # A write within a life advances the count by two.
  def written(slot, **fields) = slot.with(seq: slot.seq + 2, **fields)

  # A life's closing write: free the slot, or retire it when its next
  # generation is never issued or its count leaves no room for a life.
  def close(table, index, generation)
    slot = table.slots.fetch(index)
    retire = generation >= GENERATION_LIMIT || slot.seq + 2 > FREE_MAX
    closed = slot.with(state: retire ? :retired : :free, generation: generation, object: 0, type: 0, rights: 0,
                       seq: retire ? TERMINAL : slot.seq + 2)
    table.with_slot(index, closed).with(free: retire ? table.free : (table.free + [index]).freeze)
  end

  def install(table, object, type, rights)
    return [table, EDEAD, 0] if table.emptied
    return [table, EINVAL, 0] if object.zero? || CARRY.fetch(type, 0).zero? || (rights & ~CARRY.fetch(type)) != 0
    return [table, ELIMIT, 0] if table.free.empty?

    index = table.free.first
    slot = table.slots.fetch(index)
    taken = table.with(free: table.free.drop(1).freeze)
    [taken.with_slot(index, written(slot, state: :live, object: object, type: type, rights: rights)), OK,
     value(index, slot.generation)]
  end

  def names?(table, index, generation, object)
    return false if index.zero? || index >= table.capacity

    slot = table.slots.fetch(index)
    slot.live? && slot.generation == generation && object != 0 && slot.object == object
  end

  def clear(table, cap, object)
    index, generation = decode(cap)
    return [table, ESTALE] unless names?(table, index, generation, object)

    [close(table, index, generation + 1), OK]
  end

  View = Data.define(:object, :type, :rights, :slot, :generation)
  NO_VIEW = View.new(object: 0, type: 0, rights: 0, slot: 0, generation: 0)

  def read(table, cap, type, required)
    index, generation = decode(cap)
    return [ESTALE, NO_VIEW] if index.zero? || index >= table.capacity

    slot = table.slots.fetch(index)
    return [ESTALE, NO_VIEW] if slot.seq == TERMINAL || !slot.live? || slot.generation != generation
    return [ETYPE, NO_VIEW] if type != 0 && slot.type != type
    return [ERIGHTS, NO_VIEW] if (slot.rights & required) != required

    [OK, View.new(object: slot.object, type: slot.type, rights: slot.rights, slot: index, generation: generation)]
  end

  def reserve(table, count)
    return [table, EINVAL] if count > MSG_CAPS
    return [table, EBUSY] unless table.held.empty?
    return [table, EDEAD] if table.emptied
    return [table, ELIMIT] if table.free.size < count

    taken = table.free.first(count)
    result = table.with(free: table.free.drop(count).freeze, held: taken.freeze)
    taken.each { |index| result = result.with_slot(index, written(result.slots.fetch(index), state: :reserved)) }
    [result, OK]
  end

  def release(table)
    result = table.held.reduce(table) do |current, index|
      next current unless index.positive? && index < current.capacity && current.slots.fetch(index).state == :reserved

      close(current, index, current.slots.fetch(index).generation)
    end
    result.with(held: [].freeze)
  end

  Item = Data.define(:cap, :op, :mask, :type, :required)
  Source = Data.define(:status, :view)
  Step = Data.define(:op, :slot, :generation, :object, :type, :rights)
  Plan = Data.define(:status, :failed, :steps)

  # The plan: the count, then each item in order (design, "Planning").
  def plan(items:, sources:, room:, from_own:, to_created:)
    count = items.size
    return Plan.new(status: EINVAL, failed: count, steps: []) if count > MSG_CAPS
    return Plan.new(status: ELIMIT, failed: count, steps: []) if count > room

    steps = []
    items.each_with_index do |item, index|
      status = item_status(item, sources, index, from_own: from_own, to_created: to_created)
      return Plan.new(status: status, failed: index, steps: []) unless status == OK

      view = sources[index].view
      rights = view.rights & item.mask
      rights &= to_created ? ~RIGHTS.fetch(:code) : PASS.fetch(view.type, 0)
      rights &= RIGHTS.fetch(:inspect) if to_created && view.type == TYPE_NUMBER.fetch(:space)
      steps << Step.new(op: item.op, slot: view.slot, generation: view.generation, object: view.object,
                        type: view.type, rights: rights & 0xffff_ffff)
    end
    Plan.new(status: OK, failed: count, steps: steps)
  end

  def item_status(item, sources, index, from_own:, to_created:)
    source = sources[index]
    view = source.view
    return source.status unless source.status == OK
    return EINVAL if sources.first(index).any? { |earlier| earlier.view.slot == view.slot }
    return EINVAL unless [COPY, MOVE].include?(item.op)
    return ETYPE if item.type != 0 && item.type != view.type
    return ERIGHTS if (view.rights & item.required) != item.required
    return ERIGHTS if from_own && (view.rights & RIGHTS.fetch(:give)).zero?
    return ERIGHTS if item.op == COPY && (view.rights & RIGHTS.fetch(:dup)).zero?
    return ETYPE if !to_created && PASS.fetch(view.type, 0).zero?

    OK
  end

  # The take step of an accepted plan whose sources are unchanged: a
  # reservation shorter than the plan is refused, changing nothing;
  # otherwise each move clears its source. Returns the source table and
  # the status.
  def pass_take(table, plan:, held:)
    return [table, ELIMIT] if held.size < plan.steps.size

    [plan.steps.select { |step| step.op == MOVE }
         .reduce(table) { |current, step| close(current, step.slot, step.generation + 1) }, OK]
  end

  # The install step of a taken plan: an emptied destination receives
  # nothing; a reservation that no longer holds the plan is refused
  # before any fill;
  # otherwise the passed capabilities fill the reservation in order.
  # Returns the destination table, the status and the results.
  def pass_install(table, plan:)
    return [table, EDEAD, []] if table.emptied

    held = table.held.first(plan.steps.size)
    unless held.size == plan.steps.size && held.all? { |index| table.slots.fetch(index).state == :reserved }
      return [table, EINVAL, []]
    end

    filled = plan.steps.zip(held).reduce(table) do |current, (step, index)|
      current.with_slot(index, written(current.slots.fetch(index), state: :live, object: step.object,
                                                                    type: step.type, rights: step.rights))
    end
    results = plan.steps.zip(held).map { |step, index| [value(index, table.slots.fetch(index).generation), step.type, step.rights] }
    [filled.with(held: table.held.drop(plan.steps.size).freeze), OK, results]
  end
end
