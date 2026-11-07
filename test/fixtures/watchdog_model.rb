# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/generated_abi'

# The kernel watchdog's contract, written from the design's statements and
# the core's documented choices where the design is silent, rather than
# from kernel/core/watchdog.c. It does not keep a deadline: it keeps the
# last instant the root task proved itself (its start, then each pet that
# came in time) and how long that proof lasts (the boot deadline B before
# the first pet, the deadline D after). Ruby integers do not overflow, so a
# proof that lasts past the clock's last instant simply never expires; the
# core must reach the same outcome with checked 64-bit arithmetic.
#
# From the design:
# * The start arms the watchdog B ahead; in deterministic mode it turns the
#   watchdog off instead, after which nothing ever ends and pets are
#   accepted without effect.
# * A pet renews the proof, D ahead of the pet.
# * A tick past the end of the proof ends the machine with cause watchdog,
#   the tick's time as uptime and the time since the proof as since_pet;
#   every other tick reloads the board's hardware watchdog.
# The core's choices where the design is silent:
# * The end of the proof is still on time: a pet at it renews, a tick at
#   it reloads. A later pet renews nothing, so only a tick ends.
# * Before the start nothing ends and a pet changes nothing; a later start
#   changes nothing.
# * The core's stored deadline saturates at the clock's last instant.
module WatchdogModel
  CODEC = Erx::ABI::Generated::CODEC
  NS_PER_S = 1_000_000_000
  CLOCK_MAX = (1 << 64) - 1
  WATCHDOG_CAUSE = CODEC.member('crash_cause', 'watchdog')
  PANIC_CAUSE = CODEC.member('crash_cause', 'panic')

  Config = Data.define(:period_s, :deadline_s, :boot_s)
  Expectation = Data.define(:action, :since_pet_ns)

  # phase is :unstarted, :armed or :off; proof_ns and lasts_ns describe the
  # current proof while armed.
  Spec = Data.define(:mode, :config, :phase, :proof_ns, :lasts_ns) do
    def self.initial(mode:, config:) = new(mode: mode, config: config, phase: :unstarted, proof_ns: nil, lasts_ns: nil)

    # The expected outcome of one event and the spec that follows it.
    def on(kind, now_ns)
      case kind
      in :start then start(now_ns)
      in :pet then pet(now_ns)
      in :tick then tick(now_ns)
      end
    end

    def expired?(now_ns) = phase == :armed && now_ns > proof_ns + lasts_ns

    # The core's stored state that this spec stands for: phase, since and
    # deadline, with times zero unless armed.
    def core_state
      case phase
      in :unstarted then [:unarmed, 0, 0]
      in :off then [:off, 0, 0]
      in :armed then [:armed, proof_ns, [proof_ns + lasts_ns, CLOCK_MAX].min]
      end
    end

    private

    def start(now_ns)
      return [Expectation.new(action: :none, since_pet_ns: nil), self] unless phase == :unstarted
      return [Expectation.new(action: :none, since_pet_ns: nil), with(phase: :off)] if mode == :det

      [Expectation.new(action: :arm, since_pet_ns: nil),
       with(phase: :armed, proof_ns: now_ns, lasts_ns: config.boot_s * NS_PER_S)]
    end

    def pet(now_ns)
      renewed = phase == :armed && !expired?(now_ns)
      next_spec = renewed ? with(proof_ns: now_ns, lasts_ns: config.deadline_s * NS_PER_S) : self
      [Expectation.new(action: :none, since_pet_ns: nil), next_spec]
    end

    def tick(now_ns)
      return [Expectation.new(action: :end, since_pet_ns: now_ns - proof_ns), self] if expired?(now_ns)

      [Expectation.new(action: :reload, since_pet_ns: nil), self]
    end
  end
end
