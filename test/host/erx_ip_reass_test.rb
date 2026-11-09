# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs IP reassembly's EUnit cases, test/erlang/erx_ip_reass_tests.erl: the
# byte-map property for IPv4 and IPv6, the caps, ECN, expiry and errors. Then
# runs them again over a copy of erx_ip_reass seeded with the fault the
# design names, a reassembly that accepts overlapping IPv6 fragments, which
# the property must catch (docs/design-network-stack.md, "Reassembly and
# buffers: properties against a byte map").
class ErxIpReassTest < Minitest::Test
  include ErxNetEunit

  OVERLAP = "{[#frag{'end' = PrevEnd} | _], _} when PrevEnd > Off -> {discard, overlap};"
  ACCEPTS_OVERLAP = "{[#frag{'end' = PrevEnd} | _], _} when PrevEnd > Off, false -> {discard, overlap};"

  def test_reassembly_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_ip_reass_tests)
  end

  def test_property_catches_overlapping_ipv6_fragments_accepted
    output = refute_erx_net_eunit(:erx_ip_reass_tests, fault: { 'erx_ip_reass' => [OVERLAP, ACCEPTS_OVERLAP] })
    assert_match(/ip6_matches_byte_map_test/, output)
  end
end
