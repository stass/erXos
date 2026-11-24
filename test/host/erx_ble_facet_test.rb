# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/erx_ble_facet'

# Runs test/erlang/erx_ble_facet_tests.erl, the cases of the ble facet, erx_ble_facet, in
# front of the real registry, erx_gatt_srv, and of its mint below erx_bt_top
# (docs/design-bluetooth.md, "The `ble` facet" and "Verification"), on stock's emulator
# (ERX_ERL and ERX_ERLC). Then each seeded fault, applied to a copy of its module, must
# fail the case named for it.
class ErxBleFacetTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  # The connection table's stand-in answers noconnection for a grantee the test sets none for.
  TESTS = %w[test/erlang/erx_ble_facet_tests.erl test/erlang/stand_in/erx_connections.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  FACET = 'erlang/apps/erx_bt/src/erx_ble_facet.erl'
  SRV = 'erlang/apps/erx_bt/src/erx_gatt_srv.erl'

  Seed = Data.define(:fault, :path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the service check dropped from admit/3, so another app's service is attached",
             path: FACET, anchor: 'forward(lists:member(Service, Services), Request, Caller, Grant)',
             replacement: 'forward(true, Request, Caller, Grant)',
             catching_case: 'a_request_naming_another_service_is_refused_test'),
    Seed.new(fault: "the registry's pid kept from the facet's first request, so the request after a restart fails",
             path: FACET, anchor: "    case whereis(erx_gatt_srv) of\n",
             replacement: "    put(registry, case get(registry) of undefined -> whereis(erx_gatt_srv); Kept -> Kept end),\n" \
                          "    case get(registry) of\n",
             catching_case: 'the_facet_outlives_a_registry_restart_test'),
    Seed.new(fault: "the handler taken from the forwarded call's From, so the events go to the facet",
             path: SRV, anchor: "handle_call({facet, Caller, Op}, From, Srv) ->\n    step({facet, Caller, Op, From}, Srv).",
             replacement: "handle_call({facet, _Caller, Op}, {Facet, _} = From, Srv) ->\n    step({facet, Facet, Op, From}, Srv).",
             catching_case: 'the_caller_hears_the_events_and_alone_answers_its_writes_test'),
    Seed.new(fault: 'a reply of any shape forwarded, so the facet bounds no answer',
             path: FACET, anchor: 'answer(_Answer) -> false.', replacement: 'answer(_Answer) -> true.',
             catching_case: 'a_request_of_no_operation_s_shape_is_refused_badarg_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}(?:(?!erx_ble_facet_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  def test_fuzz_seeds_still_name_the_facet
    text = File.read(File.join(ErlangBuild::ROOT, FACET))
    ErxBleFacetFuzz::SEEDS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "fuzz seed #{fault.name}: its text must occur once in #{FACET}"
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-ble-facet-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', 'halt(case eunit:test([erx_ble_facet_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
