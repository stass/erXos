# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The plan of an app's session (docs/design-packaging.md, "An app's session"):
# test/erlang/erx_app_session_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_domain_core as it is, and against each seeded
# fault of the design's verification row below, where the named case must fail.
class ErxAppSessionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_domain/src/erx_domain_core.erl'
  APPLICATIONS = %w[erx erx_files erx_domain].freeze
  TESTS = %w[test/erlang/erx_app_session_tests.erl].freeze

  # Each fault replaces passages of erx_domain_core, each [from, to]; the case named in
  # caught_by must fail.
  Fault = Data.define(:name, :edits, :caught_by)

  PLAN_HEAD = "app_session(Name, \#{entry := Entry, memory := Memory, rows := Kept, ble := Ble}, " \
              "\#{first := First}, TemplateRows) ->\n"
  KEPT_ROWS = 'rows => [Granted || {Index, Row} <- TemplateRows, Granted <- granted(Index, Row, Kept, Ble)]'
  NARROWED = 'Limits#{services := [Service || Service <- Offered, lists:member(Service, Gatt)]}'

  FAULTS = [
    Fault.new(name: 'a plan that grants every row of the template',
              edits: [[KEPT_ROWS, 'rows => [Row || {_Index, Row} <- TemplateRows, Kept =/= x, Ble =/= x]']],
              caught_by: 'the_rows_are_packages_system_and_the_needs_test'),
    Fault.new(name: "a plan that passes the ble row's set whole",
              edits: [[NARROWED, 'Limits#{services := Offered ++ (Gatt -- Gatt)}']],
              caught_by: 'the_ble_row_names_the_records_services_test'),
    Fault.new(name: "a plan that grants the record's services, not their intersection with the row's",
              edits: [[NARROWED, 'Limits#{services := Gatt ++ (Offered -- Offered)}']],
              caught_by: 'the_ble_row_is_never_wider_than_the_templates_test'),
    Fault.new(name: "a scope computed from the template's key",
              edits: [[PLAN_HEAD,
                       "app_session(Name, \#{entry := Entry, memory := Memory, rows := Kept, ble := Ble}, " \
                       "\#{template := Template}, TemplateRows) ->\n    First = Template,\n"]],
              caught_by: 'every_scope_names_the_apps_principal_test'),
    Fault.new(name: "a plan that grants an image package the template's whole row set",
              edits: [[PLAN_HEAD,
                       "app_session(Name, \#{signer := image} = App, Apps, TemplateRows) ->\n" \
                       "    (app_session(Name, App\#{signer := none}, Apps, TemplateRows))" \
                       "\#{rows := [Row || {_, Row} <- TemplateRows]};\n#{PLAN_HEAD}"]],
              caught_by: 'one_header_admitted_both_ways_gives_one_plan_test'),
    Fault.new(name: 'a session given the apps budget for its memory',
              edits: [[PLAN_HEAD,
                       "app_session(Name, \#{entry := Entry, rows := Kept, ble := Ble}, " \
                       "\#{first := First, memory := Memory}, TemplateRows) ->\n"]],
              caught_by: 'the_memory_is_the_declared_one_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      seeded = fault.edits.reduce(File.read(File.join(ROOT, CORE))) do |text, (from, to)|
        assert_equal 1, text.scan(from).size, "#{fault.name}: passage not found once"
        text.sub(from) { to }
      end
      output, status = eunit(seeded)
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_app_session_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the core as core_text, the applications and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-app-session-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_app_session_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
