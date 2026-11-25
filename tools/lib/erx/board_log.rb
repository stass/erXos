# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'bench_record'
require_relative 'board_files'
require_relative 'error'
require_relative 'native_bench'

module Erx
  # The one reader of a board's console log (docs/design-bench.md, "Importing a log"):
  # a pure function of the log's bytes, the queue it was a walk of (BoardFiles::Queue),
  # what each of the queue's sets asked (BenchMeasurement::Asked, by set index) and the
  # walk's outcomes when it has them (BoardFiles::Walk, or nil).
  #
  # Placement is the construction's rule ("The construction: the server hands out a
  # queue"): a line naming an entry, and every line between two consecutive edges that
  # both name that entry, belong to that entry's boot; every other line belongs to none.
  # An edge is a naming line, a banner or the machine's end line. A banner or an end
  # line starts or ends a boot, so no bracket spans two boots; a naming line with a name
  # of no entry, or broken, brackets nothing, so a line next to a lost or damaged edge is
  # lost to its cell rather than judged with another boot's. An entry whose naming lines
  # lie on both sides of a banner or of another entry's naming line booted twice, and
  # every cell of it is rejected.
  #
  # Every byte of the log is the board's and untrusted: lines reach only
  # BenchMeasurement.boot, the bench lines' one judge; nothing of their text comes back
  # but the per-boot slices of the log, each at most a boot's bound.
  module BoardLog
    # What a banner names (docs/design-bench.md, "The record of a board run"): the
    # handoff's build and index hash, at their exact sizes.
    BANNER = /\Aerx: boot image build (?<build>[0-9a-f]{16}) index (?<index>[0-9a-f]{64}) /n
    TWICE = 'its entry booted twice'
    UNNAMED = 'no line of the log names its boot'
    CUT = 'the log ends before its boot did'
    UNSEEN = 'the end of its boot was not seen'

    # A line the reader keeps, an edge or a guest line, with the byte offset just past its
    # line end. kind is :naming (name nil when broken), :banner, :end or :guest; text is
    # kept for a banner and a guest line.
    Kept = Data.define(:kind, :stop, :name, :form, :text)
    # What the log holds of one queued boot name: the indexes in the kept lines of its
    # naming lines, their end forms, its guest lines, and whether it booted twice.
    Named = Data.define(:naming, :forms, :guest, :twice)
    NONE = Named.new(naming: [], forms: [], guest: [], twice: false)
    # An entry's boot: the entry (BoardFiles::Entry), its slice of the log, how it ended
    # ('done', 'deadline' or nil), and BenchMeasurement.boot's clock group, cells and
    # refused reasons.
    Boot = Data.define(:entry, :log, :ended, :clock, :cells, :refused)
    # The log read: one Boot per bench entry in position order, and what the board
    # booted after the last (BoardFiles::Returned), the walk's when it has one.
    Read = Data.define(:boots, :returned)

    module_function

    # The most bytes a log of queue holds: a boot's bound for each entry and the return
    # (BenchRecord::LOG_BYTES, which the walk holds each boot to).
    def max_bytes(queue) = (queue.entries.size + 1) * BenchRecord::LOG_BYTES

    def read(log, queue:, asked:, walk: nil)
      raise Error, 'board log: the log is larger than its queue allows' if log.bytesize > max_bytes(queue)
      raise Error, 'board log: the walk does not have one outcome per entry' if walk && walk.outcomes.size != queue.entries.size

      bytes = log.b
      kept = kept(bytes)
      named = named(kept, queue)
      of = ->(entry) { named.fetch(entry.name, NONE) }
      # Each boot's slice runs from the end of the one before to its own stop, never
      # backwards, and the last runs to the end of the log, the return among it.
      ends = queue.entries.each_with_object([]) { |entry, made| made << [stop(kept, of.(entry)), made.last || 0].max }
      ends[-1] = bytes.bytesize
      boots = queue.entries.zip([0, *ends], ends).map do |entry, start, stop|
        slice = bytes.byteslice(start, stop - start)
        raise Error, "board log: boot #{entry.position} is larger than a boot's log may be" if slice.bytesize > BenchRecord::LOG_BYTES

        boot(entry, slice, kept: kept, named: of.(entry), asked: asked.fetch(entry.set), walk: walk)
      end
      Read.new(boots: boots, returned: walk ? walk.returned : returned(kept, of.(queue.entries.last), queue))
    end

    # The edges and guest lines of the log, in order.
    def kept(bytes)
      stop = 0
      bytes.each_line("\n").filter_map do |raw|
        stop += raw.bytesize
        classify(raw.delete_suffix("\n").sub(/\r+\z/n, ''), stop)
      end
    end

    def classify(text, stop)
      if NativeBench::NAMING_HEAD.match?(text)
        found = NativeBench::NAMING_LINE.match(text)
        Kept.new(kind: :naming, stop: stop, name: found&.[](:name), form: found&.[](:form), text: nil)
      elsif BANNER.match?(text) then Kept.new(kind: :banner, stop: stop, name: nil, form: nil, text: text)
      elsif NativeBench::MACHINE_END_LINE.match?(text) then Kept.new(kind: :end, stop: stop, name: nil, form: nil, text: nil)
      elsif NativeBench::GUEST_LINE.match?(text) then Kept.new(kind: :guest, stop: stop, name: nil, form: nil, text: text)
      end
    end

    # Each queued name the log holds, as Named, in one pass. open is the queued name of
    # the last edge, nil after any other edge; the guest lines since that edge go to open
    # when the next edge names it too. runs is the order of queued names and banners,
    # each run once, so a name in two runs booted twice.
    def named(kept, queue)
      queued = queue.entries.to_h { |entry| [entry.name, true] }
      naming = Hash.new { |hash, name| hash[name] = [] }
      guest = Hash.new { |hash, name| hash[name] = [] }
      runs = []
      open = nil
      pending = []
      kept.each_with_index do |line, index|
        next pending << line.text if line.kind == :guest

        guest[open].concat(pending) if open && line.name == open
        pending = []
        open = line.kind == :naming && queued.key?(line.name) ? line.name : nil
        runs << :banner if line.kind == :banner
        next unless open

        naming[open] << index
        runs << open unless runs.last == open
      end
      naming.to_h do |name, indexes|
        [name, Named.new(naming: indexes, forms: indexes.map { |index| kept[index].form }, guest: guest[name],
                         twice: runs.count(name) > 1)]
      end
    end

    # Where a boot's own bytes stop: its last naming line, or the machine's end line after
    # it before the next banner or naming line that names a boot; 0 for a boot no line
    # names.
    def stop(kept, named)
      last = named.naming.last
      return 0 if last.nil?

      ending = kept.drop(last + 1).take_while { |line| line.kind != :banner && !(line.kind == :naming && line.name) }
                   .find { |line| line.kind == :end }
      (ending || kept[last]).stop
    end

    def boot(entry, slice, kept:, named:, asked:, walk:)
      ended = %w[deadline done].find { |form| named.forms.include?(form) }
      if named.twice
        return Boot.new(entry: entry, log: slice, ended: ended, clock: nil,
                        cells: BenchMeasurement.rejected(asked, reason: TWICE), refused: [TWICE])
      end

      outcome = walk&.outcome(entry.position)
      stopped = walk.ending if outcome == 'stopped'
      judged = BenchMeasurement.boot(named.guest, asked, timed_out: ended == 'deadline' || stopped == 'end_deadline',
                                                         not_run: not_run(kept, named, ended: ended, outcome: outcome, stopped: stopped))
      Boot.new(entry: entry, log: slice, ended: ended, clock: judged.fetch(:clock), cells: judged.fetch(:cells),
               refused: judged.fetch(:refused))
    end

    # The reason an unreported cell of the entry is not_run: no naming line, the walk's
    # reason for stopping in it, an end seen without its done or deadline line (a later
    # edge), or the log ending first.
    def not_run(kept, named, ended:, outcome:, stopped:)
      return UNNAMED if named.naming.empty?
      return BenchMeasurement::NOT_RUN if ended
      return BoardFiles::STOPPED_BY[stopped] if BoardFiles::STOPPED_BY.key?(stopped)
      return UNSEEN if outcome == 'ended_unseen' || kept.drop(named.naming.last + 1).any? { |line| line.kind != :guest }

      CUT
    end

    # What the log shows the board booted after the last entry: the first banner after
    # its last naming line, held to the queue's return identity.
    def returned(kept, last, queue)
      banner = last.naming.last && kept.drop(last.naming.last + 1).find { |line| line.kind == :banner }
      return BoardFiles::Returned.new(status: 'not_seen') if banner.nil?
      return BoardFiles::Returned.new(status: 'unknown') if queue.return_identity.nil?

      found = BANNER.match(banner.text)
      identity = BoardFiles::Identity.new(build: found[:build], index: found[:index])
      return BoardFiles::Returned.new(status: 'booted') if identity == queue.return_identity

      BoardFiles::Returned.new(status: 'unexpected', identity: identity)
    end

    private_class_method :kept, :classify, :named, :stop, :boot, :not_run, :returned
  end
end
