# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the network stack's effect layer: the interface core against
# canned frames (test/erlang/erx_net_if_core_tests.erl) and the driver and pipe with a
# stand-in interface (erx_net_driver_tests.erl), and seeds the faults the design names for
# them ("The stack on a development host", "The driver and the clock"; "Receiving").
class ErxNetEffectTest < Minitest::Test
  include ErxNetEunit

  def test_interface_core_passes_under_eunit
    assert_erx_net_eunit(:erx_net_if_core_tests)
  end

  def test_driver_and_pipe_pass_under_eunit
    assert_erx_net_eunit(:erx_net_driver_tests)
  end

  # A failed check that keeps the token it spent starves the interface of its bucket.
  def test_core_that_keeps_a_failed_frames_token_fails
    output = refute_erx_net_eunit(:erx_net_if_core_tests, fault: {
      'erx_net_if_core' => ['Core#core{bucket = B#bucket{tokens = min(Burst * ?TOKEN, T + ?TOKEN)}}.',
                            '_ = {T, Burst, B}, Core.']
    })
    assert_match(/failed_check_gives_its_token_back/, output)
  end

  # The design's seeded failures of the driver and the pipe, each failing its own case.
  DRIVER_FAULTS = {
    # A unit taken when the message arrives, not when the frame leaves.
    backlog_never_exceeds_the_transmit_credit: [
      'erx_net_driver',
      ["when is_list(Frames) ->\n    drain(",
       "when is_list(Frames) ->\n    ok = erx_net_credit:take(S#state.tx, length(Frames)),\n    drain("]
    ],
    # A refused link notice retried only at later messages.
    silent_link_is_told_once_room_returns: [
      'erx_net_driver',
      ["Retry = erx_net_clock:now() + ?RETRY_US,\n            S#state{armed = erx_net_clock:arm_by(Retry, S#state.armed)}", 'S']
    ],
    # Every link change queued instead of only the latest told.
    flap_while_full_is_not_told: [
      'erx_net_driver',
      ['event({link, State}, S) when State =:= up; State =:= down ->',
       "event({link, State}, #state{iface = {Pid, _, _}} = S) ->\n    Pid ! {link, self(), State}, S;\n" \
       'event({link, State}, S) when State =:= up; State =:= down ->']
    ],
    # A process end without its type check.
    process_end_counts_a_frame_that_is_not_a_binary: [
      'erx_net_pipe',
      ['#process{pid = Pid, mtu = Mtu} = T) when is_binary(Frame) ->', '#process{pid = Pid, mtu = Mtu} = T) ->']
    ],
    # A socket opened {active, true}.
    udp_end_bounds_the_driver_queue_against_a_stranger: [
      'erx_net_pipe', ['{ip, LocalIp}, {active, ?ACTIVE}]', '{ip, LocalIp}, {active, true}]']
    ]
  }.freeze

  DRIVER_FAULTS.each do |name, (mod, fault)|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_net_driver_tests, fault: { mod => fault })
      assert_match(/#{name}/, output)
    end
  end
end
