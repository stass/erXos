# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# An explicit bind's check and a listener's rewrite of its entry
# (test/erlang/erx_net_bind_tests.erl; docs/design-network-stack.md, "Explicit binds" and
# "Ports and the demultiplexing table"), with seeded faults aimed at the two properties
# that keep one grant's binds from reaching another's: rule 3, update/2's holder check and
# the bind's.
class ErxNetBindTest < Minitest::Test
  include ErxNetEunit

  def test_bind_check_and_update_pass_under_eunit
    assert_erx_net_eunit(:erx_net_bind_tests)
  end

  FAULTS = {
    # Rule 3 dropped: a reuse bind takes a port from under another grant's listener.
    another_grants_listener_refuses_whatever_the_reuse_options: [
      '(Unconnected orelse Transport =:= udp) andalso OtherGrant andalso Overlaps -> true;',
      '(Unconnected orelse Transport =:= udp) andalso OtherGrant andalso Overlaps andalso not Reuse -> true;'
    ],
    # The holder check dropped: a rewrite overwrites a key that passed to another socket.
    another_holders_key_is_left: [
      "Spec = [{{Key, Self, '$3'},",
      "Spec = [{{Key, '_', '$3'},"
    ]
  }.freeze

  # The holder check dropped: a bind inserts a key held in another process's name.
  def test_seeded_fault_fails_a_bind_for_another_process_is_refused
    fault = ['#{pid := Holder, credit := _, grant := Grant} = Entry}, {Holder, _}, Watched)',
             '#{pid := Holder, credit := _, grant := Grant} = Entry}, {_, _}, Watched)']
    output = refute_erx_net_eunit(:erx_net_bind_tests, fault: { 'erx_net_tables' => fault })
    assert_match(/a_bind_for_another_process_is_refused/, output)
  end

  FAULTS.each do |name, fault|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_net_bind_tests, fault: { 'erx_net_bind' => fault })
      assert_match(/#{name}/, output)
    end
  end
end
