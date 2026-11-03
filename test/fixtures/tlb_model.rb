# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'set'
require_relative '../../tools/generated/abi'

# A reference model of one space's translation tables and of everything a TLB
# may cache from them, used to judge invalidation plans independently of the
# planner.
#
# The tables form a tree. The root table sits at depth 0 and is never freed;
# a table at depth d has `fanout` entries, each covering entry_span(d) bytes,
# and the deepest tables' entries map single pages. A TLB may cache two kinds
# of item: the translation of a mapped page, and a walk-cache copy of an entry
# that points to a table, which stays usable for every address of that
# entry's span. The model caches every item the tables hold, which is the
# worst case a plan must survive.
#
# A removal clears entries the way a range call does: it clears mapped pages
# in the range, detaches a table whose span the range covers whole, or clears
# inside the table and then frees it if that left it empty. An item cached
# before the removal is stale when the tables no longer hold it. Applying a
# plan drops cached items by the hardware's rules: a last-level invalidation
# drops page translations at its addresses, an every-level invalidation also
# drops walk-cache copies whose span meets its addresses, and a whole-ASID
# invalidation drops everything. The plan is correct when no stale item
# survives: stale_failures is that judgement, and it is the evidence that
# does not depend on how the planner reasons. contract_failures adds the
# design's own statements about a plan (status and ASID, the fallback bound,
# the form of each invalidation, and span coverage), which restate the rule
# the planner implements and so are not independent of it.
module TlbModel
  CODEC = Erx::ABI::Generated::CODEC
  PAGE = CODEC.constant('page_size')
  BY_ADDRESS_MAX = CODEC.constant('tlb_by_address_max')

  Shape = Data.define(:fanout, :levels) do
    # Bytes one entry of a table at +depth+ covers.
    def entry_span(depth) = PAGE * (fanout**(levels - 1 - depth))
    def top = entry_span(0) * fanout
    def leaf_depth = levels - 1
  end

  # A table below the root; the entry pointing to it spans entry_span(depth - 1).
  Table = Data.define(:depth, :base)
  State = Data.define(:shape, :pages, :tables)
  Cleared = Data.define(:kind, :va, :span)
  Leaf = Data.define(:va)
  Walk = Data.define(:table, :span)
  Inval = Data.define(:reach, :va, :pages) do
    def first = va
    def last = va + (pages * PAGE)
    def by_address? = reach != :asid
  end
  Plan = Data.define(:status, :asid, :invals) do
    def whole_asid? = invals.any? { |inval| inval.reach == :asid }
  end

  module_function

  def overlaps?(first, last, other_first, other_last) = first < other_last && other_first < last

  # A sparse population: a few runs of mapped pages and the tables they need.
  def populate(shape, rng)
    pages = Set.new
    (1 + rng.rand(4)).times do
      start = rng.rand(shape.top / PAGE)
      run = 1 + rng.rand([shape.fanout * 3, 96].min)
      run.times { |offset| pages << ((start + offset) * PAGE) if start + offset < shape.top / PAGE }
    end
    tables = pages.each_with_object(Set.new) do |va, set|
      (1..shape.leaf_depth).each { |depth| set << Table.new(depth: depth, base: va - (va % shape.entry_span(depth - 1))) }
    end
    State.new(shape: shape, pages: pages.freeze, tables: tables.freeze)
  end

  # A removal range near the mapped pages: a few pages, the span of a table
  # at some depth, or an arbitrary stretch, clamped to the space.
  def removal_range(state, rng)
    shape = state.shape
    anchor = state.pages.to_a.sort.fetch(rng.rand(state.pages.size))
    first, length = case rng.rand(3)
                    when 0 then [anchor - (rng.rand(3) * PAGE), (1 + rng.rand(8)) * PAGE]
                    when 1
                      span = shape.entry_span(rng.rand(shape.leaf_depth))
                      [anchor - (anchor % span), span * (1 + rng.rand(2))]
                    else [anchor - (rng.rand(shape.fanout * 2) * PAGE), (1 + rng.rand(shape.fanout**2)) * PAGE]
                    end
    first = first.clamp(0, shape.top - PAGE)
    [first, [first + length, shape.top].min]
  end

  def cache(state)
    state.pages.map { |va| Leaf.new(va: va) } +
      state.tables.map { |table| Walk.new(table: table, span: state.shape.entry_span(table.depth - 1)) }
  end

  def held?(state, item)
    case item
    in Leaf then state.pages.include?(item.va)
    in Walk then state.tables.include?(item.table)
    end
  end

  def drops?(inval, item)
    case [inval.reach, item]
    in [:asid, _] then true
    in [:last | :every, Leaf] then item.va >= inval.first && item.va < inval.last
    in [:every, Walk] then overlaps?(item.table.base, item.table.base + item.span, inval.first, inval.last)
    in [:last, Walk] then false
    end
  end

  # The invalidations by address a removal needs, which decides the fallback.
  def needed_by_address(cleared, range_pages_max)
    cleared.sum do |entry|
      span_pages = entry.span / PAGE
      entry.kind == :page ? 1 : span_pages / [span_pages, range_pages_max].min
    end
  end

  def covered?(first, last, invals)
    pieces = invals.select { |inval| overlaps?(inval.first, inval.last, first, last) }.sort_by(&:first)
    reached = pieces.reduce(first) { |cursor, inval| inval.first <= cursor ? [cursor, inval.last].max : cursor }
    reached >= last
  end

  # The independent judgement: cached items the tables no longer hold that
  # the plan's invalidations, applied by the hardware's rules, leave behind.
  def stale_failures(before:, after:, plan:)
    survivors = cache(before).reject { |item| plan.invals.any? { |inval| drops?(inval, item) } }
    survivors.reject { |item| held?(after, item) }.first(3).map { |item| "stale #{item.inspect} survives" }
  end

  # The design's statements about a plan for this removal.
  def contract_failures(cleared:, plan:, asid:, range_pages_max:)
    problems = []
    problems << "status #{plan.status}" unless plan.status.zero?
    problems << "plan ASID #{plan.asid} for removal ASID #{asid}" unless plan.asid == asid
    problems + shape_failures(plan, cleared, range_pages_max) + coverage_failures(plan, cleared)
  end

  def shape_failures(plan, cleared, range_pages_max)
    needed = needed_by_address(cleared, range_pages_max)
    problems = []
    if needed > BY_ADDRESS_MAX
      problems << "#{needed} invalidations by address but no whole-ASID plan" unless plan.whole_asid?
      problems << 'whole-ASID plan with other invalidations' unless plan.invals.size == 1
    elsif plan.whole_asid? || plan.invals.size != needed
      problems << "#{needed} invalidations by address expected, plan has #{plan.invals.map(&:reach)}"
    end
    plan.invals.select(&:by_address?).each do |inval|
      unless inval.pages.between?(1, range_pages_max) && (inval.pages & (inval.pages - 1)).zero? &&
             (inval.va % (inval.pages * PAGE)).zero?
        problems << "malformed invalidation #{inval.inspect}"
      end
    end
    problems
  end

  # The design's statement of K9 for a plan: each cleared table entry's span
  # is covered by every-level invalidations or the whole ASID, and each
  # cleared page by any invalidation of its address or the whole ASID.
  def coverage_failures(plan, cleared)
    return [] if plan.whole_asid?

    every = plan.invals.select { |inval| inval.reach == :every }
    cleared.filter_map do |entry|
      reach = entry.kind == :table ? every : plan.invals
      "#{entry.inspect} not covered" unless covered?(entry.va, entry.va + entry.span, reach)
    end
  end

  # The test's own range call: it clears what [first, last) covers and lists
  # each cleared entry, choosing at random whether a fully covered table is
  # detached whole or emptied and then freed. Each Removal is called once;
  # +freed+ then lists [depth, :detached or :emptied] for each freed table.
  class Removal
    attr_reader :freed

    def initialize(state, first:, last:, rng:)
      @shape = state.shape
      @pages = state.pages.dup
      @tables = state.tables.dup
      @first = first
      @last = last
      @rng = rng
      @cleared = []
      @freed = []
    end

    def call
      clear_in(0, 0)
      [State.new(shape: @shape, pages: @pages.freeze, tables: @tables.freeze), @cleared.freeze]
    end

    private

    def clear_in(depth, base)
      table_last = base + (@shape.entry_span(depth) * @shape.fanout)
      return clear_pages(base, table_last) if depth == @shape.leaf_depth

      span = @shape.entry_span(depth)
      children = @tables.select do |table|
        table.depth == depth + 1 && table.base >= base && table.base < table_last &&
          TlbModel.overlaps?(table.base, table.base + span, @first, @last)
      end
      children.sort_by(&:base).each { |child| clear_child(child, span) }
    end

    def clear_pages(base, table_last)
      @pages.select { |va| va >= [base, @first].max && va < [table_last, @last].min }.sort.each do |va|
        @pages.delete(va)
        @cleared << Cleared.new(kind: :page, va: va, span: PAGE)
      end
    end

    # A table the range covers whole is detached half the time; otherwise,
    # and whenever the range covers it only in part, the removal clears
    # inside it and frees it only if that left it empty. Either way a freed
    # table's entry is listed as cleared.
    def clear_child(child, span)
      covered = child.base >= @first && child.base + span <= @last
      coin = @rng.rand(2).zero?
      if covered && coin
        detach(child, span)
        free(child, span, :detached)
        return
      end

      clear_in(child.depth, child.base)
      free(child, span, :emptied) if empty?(child, span)
    end

    def free(child, span, how)
      @tables.delete(child)
      @freed << [child.depth, how]
      @cleared << Cleared.new(kind: :table, va: child.base, span: span)
    end

    # Removes the child and everything beneath it; the child itself is the
    # one table at its depth with its base.
    def detach(child, span)
      @pages.delete_if { |va| within?(va, child, span) }
      @tables.delete_if { |table| table.depth >= child.depth && within?(table.base, child, span) }
    end

    def empty?(child, span)
      @pages.none? { |va| within?(va, child, span) } &&
        @tables.none? { |table| table.depth > child.depth && within?(table.base, child, span) }
    end

    def within?(va, child, span) = va >= child.base && va < child.base + span
  end
end
