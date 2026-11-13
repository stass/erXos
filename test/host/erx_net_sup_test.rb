# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the stack's tree, test/erlang/erx_net_sup_tests.erl: the end of
# any child of erx_net_sup ends the stack, a link's end stays under erx_net_interfaces, and
# network_ctl's units map, acted on through erx_driver_ctl, stops, starts and restarts a
# link with a minted grant intact; a configured lo0 gives only a static ip4 and ingress, and
# runs over erx_net_loop. Then the seeded faults the cases exist for.
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
    units_name_the_driver: ['erx_net_erxos', ['units([#{name := Name}]) -> #{net => {erx_net_interfaces, Name}}',
                                             'units([_]) -> #{net => {erx_net_interfaces, driver}}'],
                            /network_ctl (restarts|stops and starts) the link/],
    # A units map with a fixed interface name, erx_virtio_net's first, in place of the name
    # the transport gave the unit's interface: the case's interface is genet0, so
    # erx_net_interfaces has no vtnet0 child and the stop already fails.
    fixed_name: ['erx_net_erxos', ['units([#{name := Name}]) -> #{net => {erx_net_interfaces, Name}}',
                                  'units([_]) -> #{net => {erx_net_interfaces, vtnet0}}'],
                 /network_ctl (restarts|stops and starts) the link/],
    # A configured lo0 whose ip4 is not checked: lo0 for DHCP passes the check, and the
    # stack's start fails later, at the interface core, with no {lo0, ip4} named.
    lo0_dhcp_accepted: ['erx_net_sup', ['loopback_key({ip4, Ip4}) -> is_map(Ip4) andalso maps:without([addr, plen], Ip4) =:= #{};',
                                        'loopback_key({ip4, _Ip4}) -> true;'],
                        /a DHCP lo0 is refused/],
    # A configured lo0 whose ip4 may hold any key: a gateway passes the check and gives lo0
    # a default route.
    lo0_gateway_accepted: ['erx_net_sup', ['maps:without([addr, plen], Ip4) =:= #{}', 'true'],
                           /an lo0 with a gateway is refused/],
    # A configured lo0 that may give any key: its transport passes the check and replaces
    # erx_net_loop.
    lo0_any_key: ['erx_net_sup', ['loopback_key({_Key, _Value}) -> false.', 'loopback_key({_Key, _Value}) -> true.'],
                  /an lo0 with a transport is refused/],
    # A runtime given lo0 among its interfaces: erx_net_erxos's units map, which maps `net`
    # only for one interface, would be empty beside a configured lo0.
    lo0_given_to_the_runtime: ['erx_net_sup', ['(runtime()):children(Others)', '(runtime()):children(Loopback ++ Others)'],
                               /a configured lo0 runs over the loop/]
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
