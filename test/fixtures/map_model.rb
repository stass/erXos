# frozen_string_literal: true

require_relative '../../tools/generated/abi'

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# An independent model of the mapping-record core: a sorted array of intervals,
# scanned from end to end, written from docs/design-kernel.md ("Memory" and
# "Virtual memory") with no tree, no summaries and no shared code. It prints
# what test/fixtures/map_driver.c should print for the same script. It states the
# decisions the design leaves to this core in the same words as the core does (which
# record a split reuses, how many spares that takes), so a misreading of the design
# shared by both passes here; the hand-stated expectations of map_test.rb guard those.
class MapModel
  CODEC = Erx::ABI::Generated::CODEC

  def self.constant(name) = CODEC.constant(name)

  PAGE = constant('page_size')
  LOW = constant('user_base_min') / PAGE
  LIMIT = 1 << 52
  MAX = constant('mappings_max')
  PART = constant('range_part_pages')

  OK = 0
  EINVAL = constant('einval')
  ERIGHTS = constant('erights')
  ERANGE = constant('erange')
  ENOMEM = constant('enomem')
  EEXIST = constant('eexist')
  ESTALE = constant('estale')

  RESERVED = 1
  PRIVATE = 2
  OBJECT = 3
  DELETED = 4
  KERNEL = 5

  COMMIT = 1
  DECOMMIT = 2
  PROTECT = 3

  FIXED = 1
  NOREPLACE = 2

  NONE = 0
  R = 1
  RW = 3
  RX = 5
  RWX = 7

  Rec = Struct.new(:start, :end, :kind, :object, :offset, :prot, :ceiling, :flags, keyword_init: true) do
    def pages = self.end - start
    def text = "#{start},#{self.end},#{kind},#{object},#{offset},#{prot},#{ceiling},#{flags}"

    # The piece [from, to) of this record.
    def piece(from, to)
      moved = object.zero? ? offset : offset + (from - start)
      with_fields(start: from, end: to, offset: moved)
    end

    def with_fields(**changes) = Rec.new(**to_h, **changes)
    def overlaps?(from, to) = start < to && from < self.end

    # Two neighbours may be one record.
    def merges_with?(high)
      return false unless self.end == high.start && kind == high.kind && object == high.object
      return false unless prot == high.prot && ceiling == high.ceiling && flags == high.flags

      case kind
      when RESERVED then true
      when PRIVATE, OBJECT then offset + pages == high.offset
      else false
      end
    end
  end

  attr_reader :records

  def initialize
    @records = []
    @high = 1024
    @quiet = false
  end

  # The lines one command prints.
  def call(line)
    words = line.split
    name = words.shift
    numbers = words.map { |word| Integer(word, exception: false) || word }
    send("run_#{name}", *numbers)
  end

  private

  def tree_line
    return "T #{@records.size}" if @quiet

    (["T #{@records.size}"] + @records.map(&:text)).join(' ')
  end

  def plan_line(name, nspares:, start:, stop:, nxt: stop, done: true, clears: 0, charge: 0, trim: 0, trim_object: 0,
                trim_offset: 0)
    "= #{name} 0 #{nspares} #{start} #{stop} #{nxt} #{done ? 1 : 0} #{clears} #{charge} #{trim} #{trim_object} #{trim_offset}"
  end

  def detached_line(list) = (["D #{list.size}"] + list.map(&:text)).join(' ')

  def run_init(stop)
    @records = []
    if stop <= LOW || stop > LIMIT
      @high = 1024
      return ["= init #{EINVAL}"]
    end
    @high = stop
    ['= init 0']
  end

  def run_quiet(flag)
    @quiet = flag != 0
    []
  end

  def run_lookup(page)
    found = @records.find { |record| record.start <= page && page < record.end }
    ["L #{found ? found.start : 0}"]
  end

  # A byte range as pages, or a status.
  def decode(addr, size)
    return EINVAL unless (addr % PAGE).zero? && (size % PAGE).zero? && size.positive?

    start = addr / PAGE
    stop = start + (size / PAGE)
    return ERANGE if start < LOW || stop > @high

    [start, stop]
  end

  def valid_prot?(prot) = [NONE, R, RW, RX].include?(prot)
  def beneath?(prot, ceiling) = (prot & ~ceiling).zero?

  def fields_status(kind, object, offset, prot, ceiling, flags)
    return EINVAL unless (RESERVED..KERNEL).cover?(kind)
    return EINVAL unless valid_prot?(prot) && (ceiling & ~RWX).zero? && (flags & ~1).zero?

    names_object = [PRIVATE, OBJECT].include?(kind)
    return EINVAL if names_object == object.zero?
    return EINVAL if !names_object && !offset.zero?
    return EINVAL if [PRIVATE, RESERVED].include?(kind) && ceiling != RW
    return EINVAL if kind == RESERVED && (prot != NONE || !flags.zero?)

    beneath?(prot, ceiling) ? OK : ERIGHTS
  end

  # The highest hole, scanning from the base down.
  def place(pages, base)
    top = [base, @high].min
    return nil if top <= LOW

    below = @records.select { |record| record.start < top }
    below.reverse_each do |record|
      return top - pages if top > record.end && top - record.end >= pages

      top = [top, record.start].min
    end
    top - LOW >= pages ? top - pages : nil
  end

  def overlapping(start, stop) = @records.select { |record| record.overlaps?(start, stop) }

  # Takes [start, stop) out, and returns the pieces in it and the spares the cut
  # takes for them.
  def cut(start, stop)
    hit = overlapping(start, stop)
    pieces = hit.map { |record| record.piece([record.start, start].max, [record.end, stop].min) }
    outer = hit.flat_map do |record|
      left = record.start < start ? [record.piece(record.start, start)] : []
      right = record.end > stop ? [record.piece(stop, record.end)] : []
      left + right
    end
    @records = (@records - hit + outer).sort_by(&:start)
    pieces
  end

  # What a cut will use: each straddler keeps the outer piece, or two for one
  # that straddles both ends, and a spare goes for each inner piece.
  def cut_spares(start, stop)
    hit = overlapping(start, stop)
    hit.count { |record| record.start < start } + hit.count { |record| record.end > stop }
  end

  def cut_growth(start, stop)
    cut_spares(start, stop) - overlapping(start, stop).size
  end

  # Records of an object among the spares of a cut: the inner piece of a low
  # straddler, the inner piece of a high one and an outer one when one record
  # straddles both.
  def cut_added(start, stop)
    hit = overlapping(start, stop).select { |record| record.kind == OBJECT }
    hit.sum { |record| (record.start < start ? 1 : 0) + (record.end > stop ? 1 : 0) }
  end

  def after_mode(mode, nspares, lines)
    case mode
    when 'drop'
      lines << 'A dropped'
      false
    when 'short'
      return true if nspares.zero?

      lines << "A #{ENOMEM}"
      false
    else
      true
    end
  end

  # rubocop:disable Metrics/ParameterLists
  def run_insert(addr, size, vm_flags, base, kind, object, offset, object_pages, prot, ceiling, flags, mode)
    status = insert_status(addr, size, vm_flags, kind, object, offset, object_pages, prot, ceiling, flags)
    return ["= insert #{status}", tree_line] unless status == OK

    pages = size / PAGE
    if (vm_flags & FIXED).zero?
      start = place(pages, base)
      return ["= insert #{ENOMEM}", tree_line] if start.nil?
    else
      start, = decode(addr, size)
      hit = overlapping(start, start + pages)
      return ["= insert #{EEXIST}", tree_line] if hit.any? { |record| record.kind == KERNEL }
      return ["= insert #{EEXIST}", tree_line] if !hit.empty? && !(vm_flags & NOREPLACE).zero?
    end
    stop = start + pages
    return ["= insert #{ENOMEM}", tree_line] if @records.size + cut_growth(start, stop) + 1 > MAX

    spares = cut_spares(start, stop) + 1
    lines = [plan_line('insert', nspares: spares, start: start, stop: stop)]
    apply_insert(lines, mode, spares, Rec.new(start: start, end: stop, kind: kind, object: object, offset: offset,
                                              prot: prot, ceiling: ceiling, flags: flags))
    lines << tree_line
  end

  def insert_status(addr, size, vm_flags, kind, object, offset, object_pages, prot, ceiling, flags)
    return EINVAL unless (vm_flags & ~(FIXED | NOREPLACE)).zero?
    return EINVAL if !(vm_flags & NOREPLACE).zero? && (vm_flags & FIXED).zero?

    status = fields_status(kind, object, offset, prot, ceiling, flags)
    return status unless status == OK
    return EINVAL unless (size % PAGE).zero? && size.positive?
    return EINVAL if kind == KERNEL && size != PAGE
    return ERANGE if !object.zero? && offset + (size / PAGE) > object_pages
    return OK if (vm_flags & FIXED).zero?

    decoded = decode(addr, size)
    decoded.is_a?(Array) ? OK : decoded
  end
  # rubocop:enable Metrics/ParameterLists

  def apply_insert(lines, mode, spares, new)
    return unless after_mode(mode, spares, lines)

    added = cut_added(new.start, new.end) + (new.kind == OBJECT ? 1 : 0)
    pieces = cut(new.start, new.end)
    @records = (@records + [new]).sort_by(&:start)
    lines << "A 0 #{added} 0 #{new.start}"
    lines << detached_line(pieces) unless pieces.empty?
  end

  def run_release(addr, size, mode)
    decoded = decode(addr, size)
    return ["= release #{decoded}", tree_line] unless decoded.is_a?(Array)

    start, stop = decoded
    hit = overlapping(start, stop)
    return ["= release #{EEXIST}", tree_line] if hit.any? { |record| record.kind == KERNEL }
    return ["= release #{ENOMEM}", tree_line] if @records.size + cut_growth(start, stop) > MAX

    spares = cut_spares(start, stop)
    lines = [plan_line('release', nspares: spares, start: start, stop: stop)]
    if after_mode(mode, spares, lines)
      added = cut_added(start, stop)
      pieces = cut(start, stop)
      lines << "A 0 #{added} 0 0"
      lines << detached_line(pieces) unless pieces.empty?
    end
    lines << tree_line
  end

  def run_kremove(page, mode)
    found = @records.find { |record| record.start == page && record.kind == KERNEL }
    return ["= kremove #{EINVAL}", tree_line] if found.nil?

    lines = [plan_line('kremove', nspares: 0, start: found.start, stop: found.end)]
    if after_mode(mode, 0, lines)
      @records -= [found]
      lines << 'A 0 0 0 0' << detached_line([found])
    end
    lines << tree_line
  end

  def run_deleted(page)
    found = @records.find { |record| record.start <= page && page < record.end }
    return ["= deleted #{EINVAL}", tree_line] unless found.kind == OBJECT

    found.kind = DELETED
    found.object = 0
    found.offset = 0
    ['= deleted 0', tree_line]
  end

  def run_deadrecord(addr, size)
    start, stop = decode(addr, size)
    hit = overlapping(start, stop)
    @records -= hit
    ["= deadrecord #{ESTALE} #{hit.first.kind}", detached_line(hit.drop(1)), tree_line]
  end

  def run_twice(addr, size)
    start, stop = decode(addr, size)
    hit = overlapping(start, stop)
    @records -= hit
    ["= twice 0#{detached_line(hit)}", "= stale #{ESTALE}", "= spent #{EINVAL}", "= extra #{EINVAL}", tree_line]
  end

  def run_rawrelease(start, stop)
    return ["= raw #{EINVAL}"] unless start >= LOW && start < stop && stop <= @high

    ["= raw #{overlapping(start, stop).any? { |record| record.kind == KERNEL } ? EEXIST : OK}"]
  end

  # Only the refusals of the request itself: the scripts send nothing else here.
  def run_rawpart(_operation, _start, _stop, _cursor) = ["= raw #{EINVAL}"]

  def run_markstale(_addr, _size, page)
    run_deleted(page).then { |_status, tree| ["= markstale #{ESTALE}", tree] }
  end

  def run_othertree(_addr, _size) = ["= othertree #{EINVAL}", tree_line]

  def run_nexttouch(page)
    found = @records.find { |record| record.end > page && record.kind != RESERVED }
    ["L #{found ? found.start : 0}"]
  end

  def run_fill(start, count, pages)
    count.times do |index|
      page = start + ((pages + 1) * index)
      @records << Rec.new(start: page, end: page + pages, kind: RESERVED, object: 0, offset: 0, prot: NONE, ceiling: RW,
                          flags: 0)
    end
    @records.sort_by!(&:start)
    ["= fill #{count}", tree_line]
  end

  # What a part writes over the record it meets, or nil for nothing, with what
  # it reports.
  Decision = Struct.new(:after, :stop, :clears, :charge, :trim, :status, keyword_init: true)

  def decide(operation, record, start, stop, part)
    case operation
    when COMMIT then decide_commit(record, start, stop, part)
    when DECOMMIT then decide_decommit(record, start, stop)
    else decide_protect(record, start, stop, part)
    end
  end

  def commit_decision(record, start, stop, part, prot)
    return Decision.new(status: EINVAL) if part[:object].zero?

    stop = [stop, start + PART].min
    after = record.with_fields(start: start, end: stop, kind: PRIVATE, object: part[:object],
                               offset: start, prot: prot)
    Decision.new(after: after, stop: stop, clears: 0, charge: stop - start, trim: nil, status: OK)
  end

  def protection_decision(record, start, stop, prot)
    return Decision.new(stop: stop, clears: 0, charge: 0, status: OK) if record.prot == prot

    lowered = record.kind != DELETED && !(record.prot & ~prot).zero?
    after = record.piece(start, stop).with_fields(prot: prot)
    Decision.new(after: after, stop: stop, clears: lowered ? 1 : 0, charge: 0, status: OK)
  end

  def decide_commit(record, start, stop, part)
    case record.kind
    when RESERVED then commit_decision(record, start, stop, part, RW)
    when PRIVATE then protection_decision(record, start, stop, RW)
    else Decision.new(stop: stop, clears: 0, charge: 0, status: OK)
    end
  end

  def decide_decommit(record, start, stop)
    case record.kind
    when PRIVATE
      after = Rec.new(start: start, end: stop, kind: RESERVED, object: 0, offset: 0, prot: NONE, ceiling: RW, flags: 0)
      Decision.new(after: after, stop: stop, clears: 1, charge: 0, trim: record.piece(start, stop), status: OK)
    when OBJECT then Decision.new(stop: stop, clears: 1, charge: 0, status: OK)
    else Decision.new(stop: stop, clears: 0, charge: 0, status: OK)
    end
  end

  def decide_protect(record, start, stop, part)
    prot = part[:prot]
    return Decision.new(status: ERIGHTS) unless beneath?(prot, record.ceiling)
    return commit_decision(record, start, stop, part, prot) if record.kind == RESERVED && prot != NONE

    protection_decision(record, start, stop, prot)
  end

  # Writes after over the record it lies in and merges it with what lines up.
  # Returns [new list, spares, added records of an object, records given up].
  def edit(record, after)
    left = record.start < after.start ? record.piece(record.start, after.start) : nil
    right = after.end < record.end ? record.piece(after.end, record.end) : nil
    index = @records.index(record)
    low = left.nil? && index.positive? ? @records[index - 1] : nil
    high = right.nil? ? @records[index + 1] : nil
    low = nil unless low&.merges_with?(after)
    high = nil unless high && after.merges_with?(high)
    merged = after
    merged = merged.with_fields(start: low.start, offset: low.offset) if low
    merged = merged.with_fields(end: high.end) if high
    pieces = [left, merged, right].compact
    popped = [low, record, high].compact
    [pieces, popped]
  end

  def run_part(operation, addr, size, object, prot, mode, whenever)
    decoded = decode(addr, size)
    return ["= part #{decoded}", tree_line] unless decoded.is_a?(Array)

    start, stop = decoded
    part = { object: object, stop: stop, prot: prot }
    lines = []
    cursor = start
    number = 0
    loop do
      status = one_part(operation, part, cursor, lines, number == whenever ? mode : 'ok')
      break if status.nil?

      cursor = status
      number += 1
    end
    lines << tree_line
  end

  # One part: its lines, and the next cursor, or nil when the call has ended.
  def one_part(operation, part, cursor, lines, mode)
    stop = part[:stop]
    if !(COMMIT..PROTECT).cover?(operation) || (operation == PROTECT && !valid_prot?(part[:prot]))
      lines << "= part #{EINVAL}"
      return nil
    end
    record = @records.find { |candidate| candidate.end > cursor && candidate.start < stop }
    protect = operation == PROTECT
    if record.nil? || (protect && record.start > cursor)
      if protect
        lines << "= part #{ERANGE}"
        return nil
      end
      lines << plan_line('part', nspares: 0, start: cursor, stop: stop)
      after_mode(mode, 0, lines) && lines << 'A 0 0 0 0'
      return nil
    end
    if record.kind == KERNEL
      lines << "= part #{EEXIST}"
      return nil
    end
    begin_at = [record.start, cursor].max
    end_at = [record.end, stop].min
    decision = decide(operation, record, begin_at, end_at, part)
    unless decision.status == OK
      lines << "= part #{decision.status}"
      return nil
    end
    apply_part(record, decision, begin_at, stop, lines, mode)
  end

  def apply_part(record, decision, begin_at, stop, lines, mode)
    reach = decision.stop
    pieces, popped = decision.after ? edit(record, decision.after) : [[], []]
    spares = [pieces.size - popped.size, 0].max
    freed = [popped.size - pieces.size, 0].max
    if @records.size + pieces.size - popped.size > MAX
      lines << "= part #{ENOMEM}"
      return nil
    end
    trim = decision.trim
    lines << plan_line('part', nspares: spares, start: begin_at, stop: reach, done: reach >= stop,
                               clears: decision.clears, charge: decision.charge, trim: trim ? trim.pages : 0,
                               trim_object: trim ? trim.object : 0, trim_offset: trim ? trim.offset : 0)
    return nil unless after_mode(mode, spares, lines)

    added = pieces.drop(popped.size).count { |piece| piece.kind == OBJECT }
    @records = (@records - popped + pieces).sort_by(&:start) if decision.after
    lines << "A 0 #{added} #{freed} 0"
    reach >= stop ? nil : reach
  end

  # A region's fact: any record but a reservation touches it.
  def touched?(from, to) = @records.any? { |record| record.kind != RESERVED && record.overlaps?(from, to) }

  def run_edges(addr, size, span)
    decoded = decode(addr, size)
    return ["E #{decoded}"] unless decoded.is_a?(Array)
    return ["E #{EINVAL}"] if span.zero? || span > LIMIT

    start, stop = decoded
    regions = (start / span..(stop - 1) / span).map { |index| index * span }
    partial = regions.reject { |region| start <= region && region + span <= stop }
    covered = regions - partial
    from = covered.first || 0
    to = covered.empty? ? 0 : covered.last + span
    edges = partial.map { |region| "#{region}:#{touched?(region, region + span) ? 1 : 0}" }
    [(["E 0 #{from} #{to} #{!covered.empty? && touched?(from, to) ? 1 : 0}"] + edges).join(' ')]
  end
end
