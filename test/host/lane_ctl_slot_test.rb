# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'

# ERX_LANE_CTL_SLOT (abi/erx_abi.txt) is the longest connection-control
# record as one frame, rounded up to 16 (docs/design-domains.md, "The
# control table"): the frame header, then the control term and the payload
# as the domain pid encodes them with term_to_binary/1 (docs/design-
# runtime.md, "Control records"). Stock OTP encodes that record here: a
# connection_up whose pids and peer node name are of the longest node name,
# and whose integers are of their widest values. The other record, a
# connection_down, is shorter at its widest: its Reason is noconnection or
# {domain_down, D, Info}, and every integer of Info is a 64-bit one.
class LaneCtlSlotTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ERL = ENV.fetch('ERX_ORACLE_ERL') { File.join(ROOT, 'build/oracle/jit/install/bin/erl') }
  FRAME_HEADER = 8
  NODE_MAX = 255

  # Prints the bytes of the control term and of the payload.
  PROGRAM = <<~ERLANG.tr("\n", ' ')
    Node = list_to_atom(lists:duplicate(#{NODE_MAX - 2}, $a) ++ "@h"),
    Name = atom_to_binary(Node),
    Pid = binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, 16#7fff:32, 16#1fff:32, 16#ffffffff:32>>),
    U32 = 16#ffffffff, U64 = 16#ffffffffffffffff,
    Ctl = term_to_binary({22, Pid, Pid}),
    Payload = term_to_binary({erx_connection_up, U32, Node, U64, U64, U64, U32, U32, U32}),
    Down = lists:max([byte_size(term_to_binary({erx_connection_down, U32, {domain_down, U32, Info}})) ||
                      Info <- [{halt, -16#8000000000000000}, {fault, U64}, crash, stopped]]),
    io:format("~b ~b ~b~n", [byte_size(Ctl), byte_size(Payload), Down]),
    halt().
  ERLANG

  def test_the_longest_record_fits_one_slot
    skip "no stock OTP at #{ERL}" unless File.executable?(ERL)

    output, status = Open3.capture2(ERL, '-noshell', '-eval', PROGRAM, stdin_data: '')
    assert status.success?, output
    ctl, payload, down = output.split.map { |word| Integer(word) }
    longest = FRAME_HEADER + ctl + payload
    assert_equal (longest + 15) / 16 * 16, slot, "a record of #{longest} bytes"
    assert_operator down, :<, payload, 'the widest connection_down is longer than the widest connection_up'
  end

  private

  def slot
    line = File.foreach(File.join(ROOT, 'abi/erx_abi.txt')).find { |text| text.start_with?('limit lane_ctl_slot ') }
    Integer(line.split.fetch(3))
  end
end
