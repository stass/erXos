# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# The tap transport and its NIF (docs/design-network-stack.md, "The tap transport") on a
# host without a tap device: test/erlang/erx_tap_tests.erl over a Unix datagram socket
# pair and a FIFO, with the NIF built into erx_net's priv/. Each seeded fault plants in
# erx_tap_nif.c the break one case exists for, and that case must fail.
class ErxTapTest < Minitest::Test
  include ErxNetEunit

  NIF = 'erx_tap_nif.c'

  def test_tap_transport_and_nif
    assert_erx_net_eunit('erx_tap_tests', tap: true)
  end

  # A full device's EAGAIN answered as a frame taken loses the frame, which the FIFO's
  # reader counts.
  def test_seeded_eagain_taken_is_caught
    assert_seed_fails('full_device_wakes_its_writer_test',
                      ["\t\t\treturn (ERX_TAP_WRITE_FULL);", "\t\t\treturn (ERX_TAP_WRITE_TAKEN);"])
  end

  # A read buffer without its byte past the MTU cannot tell the longest frame from a longer
  # one, so the longest is dropped.
  def test_seeded_read_buffer_without_its_extra_byte_is_caught
    assert_seed_fails('short_and_long_frames_are_dropped_test',
                      ['cap = (size_t)tap->mtu + ERX_TAP_ETHER_HDR_LEN + 1;',
                       'cap = (size_t)tap->mtu + ERX_TAP_ETHER_HDR_LEN;'])
  end

  # A network sum taken from the start of the frame, over its link header, is not the sum of
  # the bytes after it, which the received frames' sums are checked against.
  def test_seeded_sum_over_the_link_header_is_caught
    assert_seed_fails('frames_cross_both_ways_test',
                      ['sum = erx_inet_sum(0, bin.data + ERX_TAP_ETHER_HDR_LEN,', 'sum = erx_inet_sum(0, bin.data,'])
  end

  # A stop callback that leaves the descriptor open keeps an armed handle's descriptor
  # after its owner has ended.
  def test_seeded_stop_without_close_is_caught
    assert_seed_fails('owner_end_closes_the_descriptor_test',
                      ['(void)close((int)event);', '(void)event;'])
  end

  # An adopt that hands its handle the caller's descriptor instead of a copy leaves the
  # handle on a number the caller's socket:close frees, and the next socket or port given
  # that number meets the handle's arm, which ERTS reports as stealing the descriptor. The
  # run is cancelled there, before adopted_descriptor_is_a_copy_test, so the report is
  # what shows the fault.
  def test_seeded_adopt_without_its_copy_is_caught
    output, status = run_erx_net_eunit(['erx_tap_tests'], extra: [], pkt: false, tap: true, fault: {},
                                       c_fault: { NIF => ['copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);',
                                                          'copy = fd;'] })
    refute status.success?, "the seeded fault #{NIF} passed:\n#{output}"
    assert_match(/stealing control of fd=/, output)
  end

  private

  def assert_seed_fails(test_case, seed)
    output = refute_erx_net_eunit('erx_tap_tests', c_fault: { NIF => seed }, tap: true)
    assert_match(/#{test_case}\.\.\.\*failed\*/, output)
  end
end
