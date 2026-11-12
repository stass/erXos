# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# The start service's processes (docs/design-apps.md, "Verification and testing"):
# test/erlang/erx_starter_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies) over a stub domain service, against the sources as they are and
# against each seeded fault below, where the named case must fail.
class ErxStarterTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APP = 'erlang/apps/erx_starter/src'
  # The application's modules, erx_ident (the core reads names with it), erx_domain (the
  # keeper's client of the domain service) and the suite.
  # Compiled before the rest: erx_starter_fs names it as its behaviour.
  BEHAVIOUR = 'erlang/apps/erx_files/src/erx_fs.erl'
  SOURCES = [*%w[erx_start_table erx_starter erx_starter_sup erx_starter_row erx_starter_keeper erx_starter_rc
                 erx_starter_fs]
              .map { |name| "#{APP}/#{name}.erl" },
             'erlang/apps/erx_domain/src/erx_ident.erl', 'erlang/apps/erx_domain/src/erx_domain.erl',
             'test/erlang/erx_starter_tests.erl', 'test/erlang/erx_starter_fs_tests.erl'].freeze

  Fault = Data.define(:name, :file, :from, :to, :caught_by)

  # Each fault replaces one passage of one source; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'a keeper that does not link to its session',
              file: "#{APP}/erx_starter_keeper.erl",
              from: 'try link(erx_domain:pid(Domain))', to: 'try erx_domain:pid(Domain)',
              caught_by: 'an_ended_session_is_started_again'),
    Fault.new(name: "a keepers' branch that restarts a row past its intensity",
              file: "#{APP}/erx_starter_sup.erl",
              from: 'restart => transient, type => supervisor', to: 'restart => permanent, type => supervisor',
              caught_by: 'one_end_past_the_intensity_leaves_the_row_down_and_others_up'),
    Fault.new(name: "a table whose crash restarts the keepers' branch",
              file: "#{APP}/erx_starter_sup.erl",
              from: '#{strategy => rest_for_one}', to: '#{strategy => one_for_all}',
              caught_by: 'a_crash_of_the_table_ends_no_session'),
    Fault.new(name: 'a restarted table that ignores the recorded text and makes the manifest\'s rows',
              file: "#{APP}/erx_starter.erl",
              from: '{ok, Text} -> make(Text, State);', to: '{ok, _Text} -> State;',
              caught_by: 'a_restart_while_rc_conf_is_unreadable_stops_no_row'),
    Fault.new(name: 'a stop that leaves no record of the stopped row',
              file: "#{APP}/erx_starter.erl",
              from: '{ok, Row} -> erx_starter_sup:stop_row(Name, Row);', to: '{ok, _Row} -> erx_starter_sup:stop(Name);',
              caught_by: 'a_stopped_row_stays_stopped_across_a_restart'),
    Fault.new(name: 'a helper that leaves the session of a keeper that ended',
              file: "#{APP}/erx_starter_keeper.erl",
              from: "{'EXIT', Keeper, _} -> exit(Pid, abandoned)", to: "{'EXIT', Keeper, _} -> ok",
              caught_by: 'a_keeper_stopped_while_its_start_is_pending_ends_the_session')
  ].freeze

  def setup
    Erx::Generated.ensure(root: ROOT)
  end

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_the_apps_tree_cases_pass
    output, status = eunit({}, mod: 'erx_starter_fs_tests')
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.file))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.file => original.sub(fault.from) { fault.to } })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name.
      assert_match(/#{Regexp.escape(fault.caught_by)}.*?\.\.\.(?:(?!erx_starter_tests: ).)*?\*(?:failed|timed out)\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the sources, each of replaced by its text there, and runs the suite mod.
  def eunit(replaced, mod: 'erx_starter_tests')
    Dir.mktmpdir('erx-starter-test') do |work|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |copy| File.write(copy, replaced.fetch(source)) }
      end
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      [[File.join(ROOT, BEHAVIOUR)], sources].each do |batch|
        output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', include, '-pa', work, '-o', work,
                                         *batch, stdin_data: '')
        assert status.success?, output
      end
      Open3.capture2e('gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test(#{mod}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
