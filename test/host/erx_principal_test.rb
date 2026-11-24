# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The registry of app principals (docs/design-packaging.md, "An app's principal"):
# test/erlang/erx_principal_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_principal as it is, and against each seeded
# fault below, where the named case must fail.
class ErxPrincipalTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_domain/src/erx_principal.erl'
  APPLICATIONS = %w[erx erx_files erx_domain].freeze
  TESTS = %w[test/erlang/erx_principal_tests.erl].freeze

  # Each fault replaces passages of erx_principal, each [from, to]; the case named in
  # caught_by must fail.
  Fault = Data.define(:name, :edits, :caught_by)

  FAULTS = [
    Fault.new(name: 'an unregister that frees an entry within the boot',
              edits: [['-export([new/1, register/2, registry/1, app/2, fetch_name/2]).',
                       '-export([new/1, register/2, registry/1, app/2, fetch_name/2, unregister/2]).'],
                      ["    maps:find(Name, Names).\n",
                       "    maps:find(Name, Names).\n\nunregister(Name, \#{names := Names} = Apps) ->\n" \
                       "    Apps\#{names := maps:remove(Name, Names)}.\n"]],
              caught_by: 'no_entry_is_freed_within_a_boot_test'),
    Fault.new(name: 'a record written in an entry the rule does not give',
              edits: [['{ok, Entry} ->', '{ok, _Given} -> Entry = map_size(Names),']],
              caught_by: 'a_name_registered_again_keeps_its_entry_and_signer_test'),
    Fault.new(name: 'credentials kept on an app principal',
              edits: [['rows := Rows, ble := Ble, display := Display}},', 'rows := Rows, display := Display} = Admitted},'],
                      ['Record = #{entry => Entry, signer => Signer, memory => Memory, rows => Rows, ble => Ble,' \
                       "\n                       app => App},",
                       'Record = Admitted#{entry => Entry, app => App},']],
              caught_by: 'a_record_holds_no_credentials_test'),
    Fault.new(name: 'a refusal of the entry rule answered ok',
              edits: [["{error, _} = Refused ->\n            Refused", "{error, _} ->\n            {ok, Apps}"]],
              caught_by: 'no_entry_is_freed_within_a_boot_test')
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
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_principal_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the registry as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-principal-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_principal_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
