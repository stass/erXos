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

  # A stop callback that leaves the descriptor open keeps an armed handle's descriptor
  # after its owner has ended.
  def test_seeded_stop_without_close_is_caught
    assert_seed_fails('owner_end_closes_the_descriptor_test',
                      ['(void)close((int)event);', '(void)event;'])
  end

  private

  def assert_seed_fails(test_case, seed)
    output = refute_erx_net_eunit('erx_tap_tests', c_fault: { NIF => seed }, tap: true)
    assert_match(/#{test_case}\.\.\.\*failed\*/, output)
  end
end
