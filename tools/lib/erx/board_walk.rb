# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'board_files'
require_relative 'board_log'

module Erx
  # The board walk's decisions (docs/design-bench.md, "The walk"): a pure state machine
  # over what the console gives, from the reboot request to the walk's end. Its input is
  # the queue's bench entries (Plan) and one event at a time; its output is the next
  # State, and once a State has ended no event changes it, so the run's one effect at the
  # end (pointing the link back) happens exactly once.
  #
  # Three deadlines bound the walk, each started at most once per entry and only ever
  # forward: the boot deadline, from the reboot request or an entry's end to the next
  # entry's first naming line; the end deadline, from that line to the entry's done or
  # deadline line, never restarted by the naming lines between; and the return deadline,
  # from the last entry's end to a banner. Every event carries the time it was read and the
  # deadline is checked before the event is, so a board that prints without pause still
  # meets it. A run lasts at most the queue's length times the boot and end deadlines, plus
  # the return's.
  #
  # Each boot's bytes are held to the byte limit as BoardLog later slices them: a boot's own
  # bytes run to its last naming line, or the end line after it, and the bytes after that go
  # to whichever boot claims them next, the next entry's or, after the last entry, the last's.
  module BoardWalk
    # The deadlines in seconds (docs/design-bench.md, "The walk", item 5).
    Deadlines = Data.define(:boot_seconds, :end_seconds, :return_seconds)
    # The walk's subject: the bench entries' boot names in queue order, the identity each
    # one's set's banner names (BoardFiles::Identity, nil when unknown), the found pair's
    # return identity (nil when unknown), the deadlines, and a boot's byte limit.
    Plan = Data.define(:names, :identities, :return_identity, :deadlines, :byte_limit)

    # What the console gives, each with the time it was read: a whole line, its text
    # classified by BoardLog.classify (nil for a line the walk does not read) and its bytes
    # with its end; bytes of a line cut at its limit, which the walk only counts; nothing
    # until at; and the console's end or an interruption, ending console_closed or
    # interrupted.
    Line = Data.define(:kept, :bytes, :at)
    Bytes = Data.define(:bytes, :at)
    Quiet = Data.define(:at)
    Stop = Data.define(:ending, :at)

    # phase is :waiting for the entry at position (the boot deadline), :running the entry
    # at position (the end deadline), :returning after the last (the return deadline) or
    # :ended. outcomes holds one BoardFiles outcome or nil (not yet decided) per entry;
    # deadline is the instant the phase's deadline passes; bytes are the current boot's own,
    # pending those read since its last own edge, and open whether an end line is still the
    # current boot's; seen is the identity of a banner read while waiting; ending and
    # returned are set once ended.
    State = Data.define(:phase, :position, :outcomes, :deadline, :bytes, :pending, :open, :seen, :ending, :returned) do
      def ended? = phase == :ended
    end

    module_function

    # The walk's state at the reboot request, at.
    def start(plan, at:)
      State.new(phase: :waiting, position: 0, outcomes: Array.new(plan.names.size).freeze,
                deadline: at + plan.deadlines.boot_seconds, bytes: 0, pending: 0, open: false, seen: nil, ending: nil,
                returned: nil)
    end

    # The state after event.
    def step(plan, state, event)
      return state if state.ended?
      return expire(state) if event.at >= state.deadline

      case event
      in Stop(ending:) then finish(state, ending)
      in Quiet then state
      in Bytes(bytes:) then limited(plan, state.with(pending: state.pending + bytes)) || state.with(pending: state.pending + bytes)
      in Line(kept:, bytes:, at:)
        counted = count(plan, state, kept, bytes)
        limited(plan, counted) || read(plan, counted, kept, at)
      end
    end

    # The walk file's value of an ended state (BoardFiles::Walk).
    def walk(state, restored:)
      BoardFiles::Walk.new(outcomes: state.outcomes, ending: state.ending, restored: restored, returned: state.returned)
    end

    # What the run says of an ended state, for a person: why the walk ended and what the
    # board needs.
    def said(plan, state)
      return BoardFiles::STOPPED_BY.fetch(state.ending) if BoardFiles::STOPPED_BY.key?(state.ending) && state.ending != 'halted'

      case state.ending
      in 'returned' then "the walk ended: every entry was sent; #{returned_said(state.returned)}"
      in 'halted' then "#{BoardFiles::STOPPED_BY.fetch('halted')}; its power needs cycling"
      in 'end_deadline'
        "the walk ended: entry #{state.position + 1} did not end within the end deadline; the board hangs below " \
          'the bench root, and its power needs cycling'
      in 'boot_deadline' then boot_deadline_said(plan, state)
      end
    end

    # The deadline of the phase has passed.
    def expire(state)
      case state.phase
      in :waiting then finish(state, 'boot_deadline')
      in :running then finish(state, 'end_deadline')
      in :returning then finish(state, 'returned')
      end
    end

    # Counts a line's bytes into the boot they belong to (the module's comment).
    def count(plan, state, kept, bytes)
      claimed = kept&.kind == :naming && kept.name && plan.names.index(kept.name)
      own = claimed && claimed == state.position && state.phase == :running
      if own
        state.with(bytes: state.bytes + state.pending + bytes, pending: 0, open: true)
      elsif claimed && state.outcomes[claimed].nil? && claimed >= state.position
        state.with(bytes: state.pending + bytes, pending: 0, open: true)
      elsif kept&.kind == :end && state.open
        state.with(bytes: state.bytes + state.pending + bytes, pending: 0, open: false)
      elsif kept&.kind == :banner || (kept&.kind == :naming && kept.name)
        state.with(pending: state.pending + bytes, open: false)
      else
        state.with(pending: state.pending + bytes)
      end
    end

    # The state ended byte_limit when the boot's bytes passed the limit, or nil. While
    # waiting with the boot before closed, the bytes since are the next boot's alone.
    def limited(plan, state)
      held = state.phase == :waiting && !state.open ? state.pending : state.bytes + state.pending
      finish(state, 'byte_limit') if held > plan.byte_limit
    end

    # What a counted line means for the walk (docs/design-bench.md, "The walk", item 4).
    def read(plan, state, kept, at)
      case kept&.kind
      in :banner then banner(plan, state, kept)
      in :end then kept.form == 'off' ? finish(state, 'halted') : state
      in :naming if kept.name then named(plan, state, plan.names.index(kept.name), kept.form, at)
      else state
      end
    end

    def banner(plan, state, kept)
      identity = identity(kept)
      case state.phase
      in :waiting then state.with(seen: identity)
      in :returning then finish(state, 'returned', returned: returned(plan, identity))
      in :running then state
      end
    end

    # A line naming the entry at index (nil for a name of no entry), with its form.
    def named(plan, state, index, form, at)
      return finish(state, 'booted_again') if index.nil? || index < state.position || !state.outcomes[index].nil?
      return state.phase == :running && form ? ended(plan, state, at) : state if index == state.position && state.phase == :running

      outcomes = state.outcomes.dup
      outcomes[state.position] = 'ended_unseen' if state.phase == :running
      ((state.phase == :running ? state.position + 1 : state.position)...index).each { |skipped| outcomes[skipped] = 'not_run' }
      begun = state.with(phase: :running, position: index, outcomes: outcomes.freeze, deadline: at + plan.deadlines.end_seconds,
                         seen: nil)
      form ? ended(plan, begun, at) : begun
    end

    # The running entry has ended: the boot deadline starts for the next, or the return
    # deadline after the last.
    def ended(plan, state, at)
      outcomes = state.outcomes.dup
      outcomes[state.position] = 'ended'
      if state.position == plan.names.size - 1
        state.with(phase: :returning, outcomes: outcomes.freeze, deadline: at + plan.deadlines.return_seconds)
      else
        state.with(phase: :waiting, position: state.position + 1, outcomes: outcomes.freeze,
                   deadline: at + plan.deadlines.boot_seconds)
      end
    end

    # The ended state: the running entry stopped, every undecided one not_run.
    def finish(state, ending, returned: BoardFiles::Returned.new(status: 'not_seen'))
      outcomes = state.outcomes.each_with_index.map do |outcome, index|
        next outcome if outcome

        state.phase == :running && index == state.position ? 'stopped' : 'not_run'
      end
      state.with(phase: :ended, outcomes: outcomes.freeze, ending: ending, returned: returned)
    end

    def identity(kept)
      found = BoardLog::BANNER.match(kept.text)
      BoardFiles::Identity.new(build: found[:build], index: found[:index])
    end

    def returned(plan, identity)
      return BoardFiles::Returned.new(status: 'unknown') if plan.return_identity.nil?
      return BoardFiles::Returned.new(status: 'booted') if identity == plan.return_identity

      BoardFiles::Returned.new(status: 'unexpected', identity: identity)
    end

    def returned_said(returned)
      case returned.status
      in 'booted' then 'the board booted the found pair again'
      in 'unexpected' then "the board booted another build, #{returned.identity.build} index #{returned.identity.index}"
      in 'unknown' then 'the board booted a build whose identity the found target does not name'
      in 'not_seen' then 'no banner came within the return deadline'
      end
    end

    def boot_deadline_said(plan, state)
      waited = "the walk ended: no line naming entry #{state.position + 1} came within the boot deadline"
      seen = state.seen
      return "#{waited}; no banner came, so the board booted nothing the walk could see" if seen.nil?
      return "#{waited}; its set's banner came, so the board hangs below the bench root, and its power needs cycling" if
        seen == plan.identities[state.position]

      "#{waited}; a banner of another build, #{seen.build} index #{seen.index}, came: the board runs it until it is reset"
    end

    private_class_method :expire, :count, :limited, :read, :banner, :named, :ended, :finish, :identity, :returned,
                         :returned_said, :boot_deadline_said
  end
end
