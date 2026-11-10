# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the check of the grant's answers,
# test/erlang/erx_sock_admit_tests.erl, and the design's two seeded failures of
# it: an open's socket taken whatever node it is of, and a change message taken
# from any domain's envelope.
class ErxSockAdmitTest < Minitest::Test
  include ErxNetEunit

  NODE_CHECK = 'socket(Grant, Pid) when is_pid(Pid), node(Pid) =:= node(Grant) -> {ok, Pid};'
  ANY_NODE = 'socket(_Grant, Pid) when is_pid(Pid) -> {ok, Pid};'
  ORIGIN_CHECK = 'when Origin =/= local, D =:= Origin ->'
  ANY_ORIGIN = 'when Origin =/= local, D =/= local ->'

  def test_answer_and_change_checks_pass_under_eunit
    assert_erx_net_eunit(:erx_sock_admit_tests)
  end

  def test_a_socket_of_another_node_is_caught
    output = refute_erx_net_eunit(:erx_sock_admit_tests, fault: { 'erx_sock_admit' => [NODE_CHECK, ANY_NODE] })
    assert_match(/open_socket_other_node/, output)
  end

  def test_another_domains_envelope_is_caught
    output = refute_erx_net_eunit(:erx_sock_admit_tests, fault: { 'erx_sock_admit' => [ORIGIN_CHECK, ANY_ORIGIN] })
    assert_match(/change_wrong_envelope/, output)
  end
end
