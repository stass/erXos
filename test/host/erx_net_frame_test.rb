# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of erx_net_frame (test/erlang/erx_net_frame_tests.erl): paths,
# route-free paths, hop limits and MTUs, frames that decode back, and a connection whose
# MTU drops in mid-transfer, and frames that erx_net_input classifies as the receiving
# interface sees them (a segment to its peer, looped broadcasts and multicasts, a looped
# ICMPv6 error in its zone); and requires each seeded failure of the design's
# "Classification and framing" to fail its case.
class ErxNetFrameTest < Minitest::Test
  include ErxNetEunit

  # Each fault: the module, its exact text, the faulty text, and the case that must fail.
  SEEDED = {
    gateway_ignored: ['erx_net_frame', '{neighbour, <<_/binary>>} -> Gateway;',
                      '{neighbour, <<_/binary>>} -> Dst;', 'gateway_and_longest_match_test'],
    ecn_in_dscp: ['erx_net_frame', '(Tos band 16#fc) bor Ecn', '(Tos band 16#fc) bor (Ecn bsl 2)',
                  'tcp_frames_decode_back_test'],
    multicast_24_bits: ['erx_net_frame', '<<_:9, Low:23>>) -> <<16#01005e:24, 0:1, Low:23>>;',
                        '<<_:8, Low:24>>) -> <<16#01005e:24, Low:24>>;',
                        'hop_limits_mtus_and_first_address_test'],
    route_for_every_destination: ['erx_net_frame',
                                  'Unrouted = erx_net_addr:is_multicast(Dst) orelse Dst =:= <<16#ffffffff:32>>,',
                                  'Unrouted = byte_size(Dst) > 16,',
                                  'route_free_paths_of_the_interface_test'],
    interface_hop_limit_for_multicast: ['erx_net_frame', '#{} when Multicast -> ?MULTICAST_HLIM;',
                                        '#{} when Multicast, Family =:= inet -> ?MULTICAST_HLIM;',
                                        'hop_limits_mtus_and_first_address_test'],
    sized_by_maxseg_alone: ['erx_tcp_output', 'case Df andalso ?IP4_TCP_HDR_LEN + Optlen + Seg#out_seg.len > Mtu of',
                            'case Df andalso Mtu < 0 of', 'mtu_drop_mid_transfer_test'],
    # The frame of a broadcast must carry the broadcast address, or the interface that gets
    # its copy back drops it as another host's.
    broadcast_to_a_unicast_address: ['erx_net_frame', '#{link := ethernet}, <<16#ffffffff:32>>) -> ?ETHER_BROADCAST;',
                                     '#{link := ethernet}, <<16#ffffffff:32>>) -> <<2, 0, 0, 0, 0, 7>>;',
                                     'looped_broadcast_and_multicast_find_a_local_socket_test'],
    loopback_drops_the_zone: ['erx_net_frame', '[{Zone, Finished} || P <- Packets, Finished <- finished(P)].',
                              '[{element(1, {global, Zone}), Finished} || P <- Packets, Finished <- finished(P)].',
                              'looped_icmpv6_error_finds_the_socket_its_quote_names_test'],
    # A delayed frame whose Start still counts from the IP header has its sum taken over
    # the wrong bytes and its field looked for 14 bytes early.
    delayed_start_left_behind_the_link_header: ['erx_net_frame', '{csum, byte_size(Header) + Start, Field, [Header, Packet]};',
                                                '{csum, Start, Field, [Header, Packet]};',
                                                'delayed_segments_finish_to_the_senders_bytes_test'],
    # A segment delayed with its checksum already finished is finished a second time.
    delayed_and_finished_by_the_sender: ['erx_net_frame', 'case packets(Path, Segment, driver, Gen0) of',
                                         'case packets(Path, Segment, sender, Gen0) of',
                                         'delayed_segments_finish_to_the_senders_bytes_test'],
    # Fragments of a delayed segment that nothing finishes leave with the partial sum.
    fragments_left_unfinished: ['erx_net_frame', "        {ok, _Fragments, _} ->\n            packets(Path, Segment, sender, Gen0);",
                                "        {ok, _Fragments, _} ->\n            packets(Path, Segment, driver, Gen0);",
                                'fragmented_segments_are_finished_by_the_sender_test'],
    # A delayed field without the pseudo-header's sum finishes to a checksum of the segment
    # alone.
    delayed_field_without_the_pseudo_header: ['erx_tcp_wire', 'erx_net_sum:add(PseudoSum, Len)',
                                              'erx_net_sum:add(0, Len)',
                                              'delayed_segments_finish_to_the_senders_bytes_test'],
    # The cut of a run (cut/1), against the run's segments encoded one by one: a last frame
    # one byte short, the timestamps only in the first frame, every frame at the first
    # sequence number, the IPv4 header checksum taken before the frame's length is stored,
    # PSH on every frame; and a run's tail one payload piece short.
    run_without_its_last_byte: ['erx_net_frame', "when Left =< Seg ->\n    [Payload];",
                                "when Left =< Seg ->\n    [element(1, split(Payload, Left - 1))];",
                                'runs_give_the_bytes_of_their_segments_test'],
    run_options_only_in_the_first_frame: ['erx_net_frame', '[Link, Ip(Len), Head, <<Sum:16>>, Tail | Slice]',
                                          '[Link, Ip(Len), Head, <<Sum:16>>, case I of 0 -> Tail; _ -> <<0:16>> end | Slice]',
                                          'runs_give_the_bytes_of_their_segments_test'],
    run_sequence_not_advanced: ['erx_net_frame', '((Seq + I * Seg) band 16#ffffffff):32, Ack:32, Off:4,',
                                'Seq:32, Ack:32, Off:4,', 'runs_give_the_bytes_of_their_segments_test'],
    run_ipv4_checksum_before_the_length: [
      'erx_net_frame', 'Sum = bnot erx_bytes:inet_csum(0, [Head, Src, Dst]) band 16#ffff,',
      'Sum = bnot erx_bytes:inet_csum(0, [<<4:4, 5:4, Tos, 0:16, IdFrag:32, Ttl, Proto>>, Src, Dst]) band 16#ffff,',
      'runs_give_the_bytes_of_their_segments_test'
    ],
    run_push_on_every_frame: ['erx_net_frame', 'Flags band bnot (?TH_PUSH bor ?TH_FIN).', 'Flags band bnot ?TH_FIN.',
                              'runs_give_the_bytes_of_their_segments_test'],
    run_tail_a_piece_short: ['erx_net_frame', 'payload = Rest}.', 'payload = tl(Rest)}.',
                             'run_tail_cuts_to_the_last_frames_test'],
    run_over_the_piece_bound: ['erx_net_frame', 'length(Payload) =< ?RUN_PIECES ->', 'length(Payload) >= 0 ->',
                               'run_over_the_piece_bound_goes_as_segments_test']
  }.freeze

  def test_framing_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_frame_tests)
  end

  SEEDED.each do |name, (mod, exact, faulty, failing)|
    define_method("test_seeded_#{name}_is_caught") do
      output = refute_erx_net_eunit(:erx_net_frame_tests, fault: { mod => [exact, faulty] })
      assert_match(/#{failing}/, output)
    end
  end
end
