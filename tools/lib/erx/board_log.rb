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
  # queue"): a line naming an entry, and every line between two consecutive naming lines
  # of that one entry, belong to that entry's boot; every other line belongs to none. A
  # naming line with a name of no entry, or with the naming head and anything else after
  # it, brackets nothing, so a line next to a lost or damaged naming line is lost to its
  # cell rather than judged with another boot's. An entry with another entry's naming
  # line between two of its own booted twice, and every cell of it is rejected.
  #
  # Every byte of the log is the board's and untrusted: lines reach only
  # BenchMeasurement.boot, the bench lines' one judge, and nothing of their text comes
  # back but the per-boot slices of the log.
  module BoardLog
    # What a banner names (docs/design-bench.md, "The record of a board run"): the
    # handoff's build and index hash, at their exact sizes.
    BANNER = /\Aerx: boot image build (?<build>[0-9a-f]{16}) index (?<index>[0-9a-f]{64}) /n
    TWICE = 'its entry booted twice'
    UNNAMED = 'no line of the log names its boot'
    CUT = 'the log ends before its boot did'
    UNSEEN = 'the end of its boot was not seen'
    # A stopped entry's unreported cells, by the walk's ending: not_run with the walk's
    # reason, or timed_out when the end deadline passed in it.
    STOPPED = { 'booted_again' => 'the walk ended: the board booted an entry again',
                'halted' => 'the walk ended: the board halted',
                'byte_limit' => 'the walk ended: the boot passed its byte limit',
                'console_closed' => 'the walk ended: the console closed',
                'interrupted' => 'the walk ended: the run was interrupted' }.freeze

    # One line of the log: its text without its line end, and the byte offset just past
    # its line end.
    Line = Data.define(:text, :stop)
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

      lines = lines(log)
      names = lines.map { |line| naming(line.text) }
      owners = owners(names)
      queued = names.map { |name| name if name && queue.entry(name.first) }
      boots = queue.entries.each_with_object([]) do |entry, read|
        start = read.empty? ? 0 : read.last.first
        own = names.each_index.select { |index| queued[index]&.first == entry.name }
        stop = own.empty? ? start : [start, last_stop(lines, queued, own.last)].max
        stop = log.bytesize if entry.equal?(queue.entries.last)
        read << [stop, boot(entry, log.byteslice(start, stop - start), lines: lines, owners: owners, queued: queued,
                                                                       own: own, asked: asked.fetch(entry.set), walk: walk)]
      end
      Read.new(boots: boots.map(&:last), returned: walk ? walk.returned : returned(lines, queued, queue))
    end

    def lines(log)
      stop = 0
      log.b.each_line("\n").map do |raw|
        stop += raw.bytesize
        Line.new(text: raw.delete_suffix("\n").sub(/\r+\z/n, ''), stop: stop)
      end
    end

    # A naming line's [name, form], [nil, nil] for a broken one, nil for any other line.
    def naming(text)
      return unless NativeBench::NAMING_HEAD.match?(text)

      found = NativeBench::NAMING_LINE.match(text)
      found ? [found[:name], found[:form]] : [nil, nil]
    end

    # Each line's owner, the name whose boot it belongs to, or nil.
    def owners(names)
      marks = names.each_index.select { |index| names[index] }
      owners = names.map { |name| name&.first }
      marks.each_cons(2) do |before, after|
        name = names[before].first
        owners.fill(name, (before + 1)...after) if name && name == names[after].first
      end
      owners
    end

    # The stop of an entry's last naming line, at index, or of the machine's end line
    # after it, before any line naming an entry.
    def last_stop(lines, queued, index)
      ending = ((index + 1)...lines.size).lazy.take_while { |later| queued[later].nil? }
                                       .find { |later| NativeBench::MACHINE_END_LINE.match?(lines[later].text) }
      lines[ending || index].stop
    end

    def boot(entry, slice, lines:, owners:, queued:, own:, asked:, walk:)
      forms = own.map { |index| queued[index].last }
      ended = %w[deadline done].find { |form| forms.include?(form) }
      if twice?(queued, own, entry.name)
        return Boot.new(entry: entry, log: slice, ended: ended, clock: nil, cells: BenchMeasurement.rejected(asked, reason: TWICE),
                        refused: [TWICE])
      end

      guest = owners.each_index.select { |index| owners[index] == entry.name }
                    .map { |index| lines[index].text }.grep(NativeBench::GUEST_LINE)
      outcome = walk&.outcome(entry.position)
      timed_out = ended == 'deadline' || (outcome == 'stopped' && walk.ending == 'end_deadline')
      judged = BenchMeasurement.boot(guest, asked, timed_out: timed_out,
                                                   not_run: not_run(lines, own, ended: ended, outcome: outcome, walk: walk))
      Boot.new(entry: entry, log: slice, ended: ended, clock: judged.fetch(:clock), cells: judged.fetch(:cells),
               refused: judged.fetch(:refused))
    end

    # Whether another entry's naming line lies between two of the entry's own.
    def twice?(queued, own, name)
      return false if own.empty?

      (own.first..own.last).any? { |index| queued[index] && queued[index].first != name }
    end

    # The reason an unreported cell of the entry is not_run: no naming line, the walk's
    # reason for stopping in it, an end seen without its done or deadline line, or the
    # log ending first.
    def not_run(lines, own, ended:, outcome:, walk:)
      return UNNAMED if own.empty?
      return BenchMeasurement::NOT_RUN if ended
      return STOPPED.fetch(walk.ending, UNSEEN) if outcome == 'stopped'
      return UNSEEN if outcome == 'ended_unseen' || ended_after?(lines, own.last)

      CUT
    end

    # Whether a line after index shows the boot ended: another naming line, the
    # machine's end or a banner.
    def ended_after?(lines, index)
      lines.drop(index + 1).any? do |line|
        naming(line.text) || NativeBench::MACHINE_END_LINE.match?(line.text) || BANNER.match?(line.text)
      end
    end

    # What the log shows the board booted after the last entry: the first banner after
    # its last naming line, held to the queue's return identity.
    def returned(lines, queued, queue)
      last = queued.rindex { |name| name&.first == queue.entries.last.name }
      banner = last && lines.drop(last + 1).lazy.filter_map { |line| BANNER.match(line.text) }.first
      return BoardFiles::Returned.new(status: 'not_seen') if banner.nil?
      return BoardFiles::Returned.new(status: 'unknown') if queue.return_identity.nil?

      identity = BoardFiles::Identity.new(build: banner[:build], index: banner[:index])
      return BoardFiles::Returned.new(status: 'booted') if identity == queue.return_identity

      BoardFiles::Returned.new(status: 'unexpected', identity: identity)
    end

    private_class_method :lines, :naming, :owners, :last_stop, :boot, :twice?, :not_run, :ended_after?, :returned
  end
end
