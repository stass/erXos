# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the stack's tree, test/erlang/erx_net_sup_tests.erl: the end of
# any child of erx_net_sup ends the stack, a link's end stays under erx_net_interfaces, and
# network_ctl's units map, acted on through erx_driver_ctl, stops, starts and restarts a
# link with a minted grant intact. Then the seeded faults the cases exist for.
class ErxNetSupTest < Minitest::Test
  include ErxNetEunit

  # erx_net_erxos is compiled for its units map, which the cases read from its children.
  SOURCES = %w[erlang/apps/erx/src/erx_driver_ctl.erl erlang/apps/erx_net/erxos/erx_net_erxos.erl].freeze

  FAULTS = {
    # OTP's default intensity at the top: a tables crash restarts the tables, and the stack
    # outlives it.
    tables_restart: ['erx_net_sup', ['intensity => 0, period => 1', 'intensity => 1, period => 5'], /ends the stack/],
    # A temporary link: terminate_child deletes its specification, so a start after a stop
    # finds no link.
    temporary_link: ['erx_net_sup', ["start_link_sup, [If]},\n                  restart => permanent}",
                                 "start_link_sup, [If]},\n                  restart => temporary}"],
                     /stops and starts the link/],
    # A units map that names the driver, a child of the link, not of erx_net_interfaces:
    # erx_net_interfaces has no such child, so the stop already fails.
    units_name_the_driver: ['erx_net_erxos', ['{erx_net_interfaces, vtnet0}', '{erx_net_interfaces, driver}'],
                            /network_ctl (restarts|stops and starts) the link/]
  }.freeze

  def test_stack_tree_passes_under_eunit
    assert_erx_net_eunit(:erx_net_sup_tests, sources: SOURCES)
  end

  FAULTS.each do |name, (mod, fault, failing)|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_net_sup_tests, sources: SOURCES, fault: { mod => fault })
      assert_match(failing, output)
    end
  end
end
