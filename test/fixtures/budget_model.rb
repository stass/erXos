# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/generated_abi'

# An independent model of the budget accounting, judged against the budget
# core through test/fixtures/budget_driver.c. The core keeps counters and
# passes changes up a chain; the model keeps only what was charged where
# (each reserve's counts, each budget's pins, its guarantee, cap and
# whether it is dead) and recomputes every counter from the tree after
# each step, from the design's definitions (docs/design-kernel.md,
# "Budgets"):
#
#   used(b)   = direct charges at b + the spending of b's dead children
#   carved(b) = the guarantees of b's live children
#   lent(b)   = the borrowing, max(0, spending - guarantee), of b's live
#               children
#   pinned(b) = the pins anywhere in b's tree
#
# A change is refused when it raises any live budget's spending above its
# cap, naming the refusing budget nearest the change. The model also plays
# the driver's stand-ins (the page counts, the record cache, the lists of
# charged objects and the destroy's walk) step for step, so it predicts
# every line the driver prints.
class BudgetModel
  CODEC = Erx::ABI::Generated::CODEC
  OK = 0
  EINVAL = CODEC.constant('einval')
  ESTALE = CODEC.constant('estale')
  ENOMEM = CODEC.constant('enomem')
  ELIMIT = CODEC.constant('elimit')
  EBUSY = CODEC.constant('ebusy')
  WALL = CODEC.constant('budget_wall')
  ELASTIC = CODEC.constant('budget_elastic')
  DEPTH_MAX = CODEC.constant('budget_depth_max')
  PART_PAGES = 64

  # A budget's own facts; its counters are derived. cache is its record
  # cache, as the core keeps it; entries its list of charged objects, as
  # [:budget, id] or [:reserve, id].
  Budget = Struct.new(:kind, :parent, :depth, :guarantee, :cap, :dead, :threshold, :watch, :pins,
                      :cache, :entries, keyword_init: true)
  # A record cache: its pages, each an array of per_page slots holding a
  # child budget's id (or :taken for a record no carve has kept yet), and
  # the order of the pages with a free slot, most recently listed first.
  Cache = Struct.new(:pages, :partial, keyword_init: true)
  Reserve = Struct.new(:budget, :charged, :backed, :pooled, keyword_init: true)
  Counters = Data.define(:used, :carved, :lent, :pinned) do
    def spending = used + carved + lent
  end
  Refusal = Class.new(StandardError) do
    attr_reader :status

    def initialize(status)
      @status = status
      super("status #{status}")
    end
  end

  attr_reader :pages

  attr_reader :per_page

  def initialize(per_page:)
    @per_page = per_page
    @next_page = 0
    @budgets = {}
    @reserves = {}
    @pending = []
    @free = 0
    @released = 0
    @pages = 0
    @next_budget = 1
    @next_reserve = 0
  end

  def budget_ids = @budgets.keys
  def reserve_ids = @reserves.keys
  def budget(id) = @budgets.fetch(id)
  def reserve(id) = @reserves.fetch(id)
  def pending = @pending.dup
  def live?(id) = !@budgets.fetch(id).dead
  def counters(id) = derive.fetch(id)

  # Runs one driver command and returns the lines the driver prints for it.
  def call(line)
    @lines = []
    @report = +''
    @refused = nil
    name, *arguments = line.split
    status = dispatch(name, arguments.map { |argument| Integer(argument) })
    tail = status == ENOMEM && @refused ? " refused=#{@refused}" : ''
    @lines << "= #{status}#{@report}#{tail}" << state_line('S')
  end

  def state_line(tag)
    all = derive
    budgets = @budgets.map do |id, b|
      c = all.fetch(id)
      " b#{id}:#{b.kind},#{b.depth},#{b.dead ? 1 : 0},#{b.guarantee},#{b.cap},#{c.used},#{c.carved}," \
        "#{c.lent},#{c.pinned},#{b.threshold},#{b.cache.pages.size}"
    end
    reserves = @reserves.map { |id, r| " r#{id}:#{r.budget},#{r.charged},#{r.backed},#{r.pooled}" }
    "#{tag} free=#{@free} rel=#{@released}#{budgets.join}#{reserves.join}"
  end

  # Every counter, recomputed from the tree, children before parents.
  def derive
    children = @budgets.keys.group_by { |id| @budgets.fetch(id).parent }
    @budgets.keys.sort_by { |id| -@budgets.fetch(id).depth }.each_with_object({}) do |id, all|
      b = @budgets.fetch(id)
      kids = children.fetch(id, [])
      live, dead = kids.partition { |kid| live?(kid) }
      direct = b.cache.pages.size + @reserves.each_value.select { |r| r.budget == id }.sum(&:charged)
      all[id] = Counters.new(
        used: direct + dead.sum { |kid| all.fetch(kid).spending },
        carved: live.sum { |kid| @budgets.fetch(kid).guarantee },
        lent: live.sum { |kid| borrowing(all.fetch(kid), @budgets.fetch(kid)) },
        pinned: b.pins + kept_pages(b.cache, all) + kids.sum { |kid| all.fetch(kid).pinned }
      )
    end
  end

  private

  # A cache page holding the record of a budget kept for the boot, one
  # whose pinned is not zero, is pinned itself.
  def kept_pages(cache, all)
    cache.pages.count do |_page, slots|
      slots.any? { |kid| kid.is_a?(Integer) && all.key?(kid) && all.fetch(kid).pinned.positive? }
    end
  end

  def borrowing(counters, budget) = [counters.spending - budget.guarantee, 0].max

  def dispatch(name, arguments)
    send(:"op_#{name}", *arguments)
  rescue Refusal => e
    e.status
  end

  def say(text) = @report << text

  # One change through the core: mutate applies it to the model's facts;
  # the change is kept only if no live budget's spending rose above its
  # cap. origin is the budget the core charges directly, and dead_rule
  # says what a dead origin refuses: a rise (:no_rise), anything
  # (:refused) or nothing (:passes).
  def change(origin, dead_rule: :no_rise, &mutate)
    before = derive
    saved = snapshot
    mutate.call
    after = derive
    rose = ->(id) { after.fetch(id).spending > before.fetch(id).spending }
    if @budgets.key?(origin) && !live?(origin) &&
       (dead_rule == :refused || (dead_rule == :no_rise && rose.call(origin)))
      restore(saved)
      raise Refusal, ESTALE
    end
    over = chain(origin).find { |id| live?(id) && rose.call(id) && after.fetch(id).spending > budget(id).cap }
    if over
      restore(saved)
      @refused = over
      raise Refusal, ENOMEM
    end
    report_effects(origin, before, after)
  end

  def chain(id)
    ids = []
    while id
      ids << id
      id = @budgets.fetch(id).parent
    end
    ids
  end

  def report_effects(origin, before, after)
    levels = chain(origin)
    levels.each do |id|
      b = budget(id)
      next unless live?(id) && b.threshold != 0 &&
                  before.fetch(id).spending < b.threshold && after.fetch(id).spending >= b.threshold

      say(" fire=#{b.watch}")
      b.threshold = 0
    end
    levels.each do |id|
      next unless !live?(id) && before.fetch(id).spending.positive? && after.fetch(id).spending.zero? &&
                  after.fetch(id).pinned.zero?

      tombstone(id)
    end
  end

  def tombstone(id)
    say(" tomb=#{id}")
    @pending << id
  end

  def snapshot = Marshal.dump([@budgets, @reserves])

  def restore(saved)
    @budgets, @reserves = Marshal.load(saved) # rubocop:disable Security/MarshalLoad
  end

  def op_root(pages)
    @pages = pages
    @free = pages
    @budgets[0] = new_budget(kind: WALL, parent: nil, depth: 0, guarantee: pages, cap: pages)
    say(" per=#{@per_page}")
    OK
  end

  def new_budget(**facts)
    Budget.new(dead: false, threshold: 0, watch: nil, pins: 0, entries: [],
               cache: Cache.new(pages: {}, partial: []), **facts)
  end

  def op_state = OK

  def op_reap
    @free += @released
    @released = 0
    OK
  end

  # The carve: one plan of the record's new cache page, when the parent's
  # cache has no free record, and the guarantee, applied together or not at
  # all, so a refused carve takes no record and charges nothing.
  def op_carve(parent, kind, guarantee, cap)
    raise Refusal, EINVAL unless [WALL, ELASTIC].include?(kind)
    raise Refusal, EINVAL if cap < guarantee || (kind == WALL && cap != guarantee)
    raise Refusal, ELIMIT if budget(parent).depth >= DEPTH_MAX - 1
    raise Refusal, ESTALE if budget(parent).dead

    id = @next_budget
    fresh = budget(parent).cache.partial.empty?
    change(parent, dead_rule: :refused) do
      cache_add_page(parent) if fresh
      page, index = cache_place(parent)
      @budgets[id] = new_budget(kind: kind, parent: parent, depth: budget(parent).depth + 1,
                                guarantee: guarantee, cap: cap)
      budget(parent).cache.pages.fetch(page)[index] = id
    end
    take_pages(1) if fresh
    @next_budget += 1
    budget(parent).entries << [:budget, id]
    say(" id=#{id}")
    OK
  end

  def op_resize(id, guarantee, cap)
    b = budget(id)
    raise Refusal, EINVAL if b.parent.nil?
    raise Refusal, EINVAL if cap < guarantee || (b.kind == WALL && cap != guarantee)
    raise Refusal, ESTALE if b.dead

    change(b.parent) do
      budget(id).guarantee = guarantee
      budget(id).cap = cap
    end
    OK
  end

  def op_reserve(id)
    raise Refusal, ESTALE if budget(id).dead

    rid = @next_reserve
    @next_reserve += 1
    @reserves[rid] = Reserve.new(budget: id, charged: 0, backed: 0, pooled: 0)
    budget(id).entries << [:reserve, rid]
    say(" id=#{rid}")
    OK
  end

  def op_charge(rid, pages, close_at = nil)
    charge(reserve(rid), reserve(rid).budget, pages, close_at)
  end

  def op_take(rid)
    r = reserve(rid)
    raise Refusal, EINVAL if r.pooled.zero?

    r.pooled -= 1
    OK
  end

  def op_release(rid, in_use, pooled)
    release(reserve(rid), reserve(rid).budget, in_use, pooled)
  end

  def op_pin(id, pages)
    change(id) { budget(id).pins += pages }
    OK
  end

  def op_watch(id, irq, threshold)
    b = budget(id)
    raise Refusal, ESTALE if b.dead
    raise Refusal, EBUSY if b.watch && b.watch != irq

    b.watch = irq
    fire = counters(id).spending >= threshold
    say(" fire=#{irq}") if fire
    b.threshold = fire ? 0 : threshold
    OK
  end

  def op_unwatch(id)
    b = budget(id)
    raise Refusal, ESTALE if b.dead

    b.watch = nil
    b.threshold = 0
    OK
  end

  def op_detach(id, irq)
    b = budget(id)
    detached = b.watch == irq
    if detached
      b.watch = nil
      b.threshold = 0
    end
    say(" detached=#{detached ? 1 : 0}")
    OK
  end

  # erx_reserve_charge as the driver composes it: admit, then back in parts.
  def charge(reserve, owner, pages, close_at)
    change(owner) { reserve.charged += pages }
    done = 0
    index = 0
    while done < pages
      if index == close_at
        change(owner) { reserve.charged -= pages - done }
        raise Refusal, ESTALE
      end
      part = [pages - done, PART_PAGES].min
      take_pages(part)
      reserve.backed += part
      reserve.pooled += part
      done += part
      index += 1
    end
    OK
  end

  def take_pages(part)
    raise 'identity: a backing found neither a free nor a released page' if part > @free + @released

    from_free = [part, @free].min
    @free -= from_free
    @released -= part - from_free
  end

  def release(reserve, owner, in_use, pooled)
    raise Refusal, EINVAL if pooled > reserve.pooled || in_use > reserve.backed - reserve.pooled

    pages = in_use + pooled
    change(owner) do
      reserve.charged -= pages
      reserve.backed -= pages
      reserve.pooled -= pooled
    end
    @released += pages
    OK
  end

  def op_destroy(id)
    raise Refusal, EINVAL if budget(id).parent.nil?

    close(id)
    walk(id)
    budget(budget(id).parent).entries.delete([:budget, id])
    OK
  end

  def close(id)
    raise Refusal, ESTALE if budget(id).dead

    change(budget(id).parent, dead_rule: :passes) { budget(id).dead = true }
    tombstone(id) if counters(id).spending.zero? && counters(id).pinned.zero?
  end

  # The walk, depth first in list order: what the core's iterative walk
  # does with its cursor, written as a recursion.
  def walk(id)
    entries = budget(id).entries
    until entries.empty?
      kind, item = entries.first
      if kind == :reserve
        r = reserve(item)
        release(r, id, r.backed - r.pooled, r.pooled)
        @reserves.delete(item)
        entries.shift
        @lines << state_line('W')
      else
        close(item)
        @lines << state_line('W')
        walk(item)
        entries.shift
        @lines << state_line('W')
      end
    end
  end

  def op_put
    due = @pending
    @pending = []
    due.each do |id|
      parent = budget(id).parent
      say(" freed=#{id}")
      slot = budget(parent).cache.pages.find { |_page, slots| slots.include?(id) }.then do |page, slots|
        [page, slots.index(id)]
      end
      @budgets.delete(id)
      cache_free(parent, slot)
    end
    OK
  end

  # A new cache page of the budget's, inside the change that charges it.
  def cache_add_page(id)
    page = @next_page
    @next_page += 1
    budget(id).cache.pages[page] = Array.new(@per_page)
    budget(id).cache.partial.unshift(page)
  end

  # Takes the lowest free record of the first page with one.
  def cache_place(id)
    cache = budget(id).cache
    page = cache.partial.first
    slots = cache.pages.fetch(page)
    index = slots.index(nil)
    slots[index] = :taken
    cache.partial.shift if slots.none?(&:nil?)
    [page, index]
  end

  # The core's free: a page that empties leaves the cache and is refunded,
  # its memory released; a full page that gains a free slot is listed first.
  def cache_free(id, (page, index))
    cache = budget(id).cache
    slots = cache.pages.fetch(page)
    was_full = slots.none?(&:nil?)
    slots[index] = nil
    if slots.all?(&:nil?)
      cache.partial.delete(page)
      change(id) { budget(id).cache.pages.delete(page) }
      @released += 1
    elsif was_full
      cache.partial.unshift(page)
    end
  end
end
