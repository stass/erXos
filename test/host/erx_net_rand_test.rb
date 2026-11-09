# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the network stack's random generator,
# test/erlang/erx_net_rand_tests.erl: its stream against SipHash, and split/1's property
# with its seeded failure.
class ErxNetRandTest < Minitest::Test
  include ErxNetEunit

  def test_generator_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_rand_tests)
  end
end
