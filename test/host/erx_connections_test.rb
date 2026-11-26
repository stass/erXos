# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/host_os'

# Runs the EUnit cases of a domain's connection agent and of erx_dist's connection
# owner (docs/design-runtime.md, "Connections in ERTS"), compiled with warnings as
# errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies):
# test/erlang/erx_connections_tests.erl, the agent's answers to its domain pid's
# records over stand-in ports, its failure paths and the records it drops, and
# test/erlang/erx_dist_tests.erl, the owner's exit decision and its following of the
# runtime's ordered end. erx_area's NIF is the host stand-in
# (test/display/erx_area_stand_in.c), so a case can hold a real area resource. Each
# seeded fault in the agent must fail the EUnit case named beside it.
class ErxConnectionsTest < Minitest::Test
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_connections_tests.erl test/erlang/erx_dist_tests.erl].freeze
  ROOT = File.expand_path('../..', __dir__)
  AREA_STAND_IN = 'test/display/erx_area_stand_in.c'

  def test_agent_cases_pass_under_eunit
    Dir.mktmpdir('erx-connections-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      area_nif(work)

      eunit(work, 'erx_connections_tests')
    end
  end

  # erx_dist's owner, at the runtime's ordered end; a halt of the runtime fails the run.
  def test_owner_cases_pass_under_eunit
    Dir.mktmpdir('erx-dist-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      eunit(work, 'erx_dist_tests')
    end
  end

  AGENT = 'erlang/apps/erx/src/erx_connections.erl'
  # The registry whose facet check the agent applies to each facet it installs.
  FACETS = 'otp/erts/preloaded/src/erx_facets.erl'
  # A seeded fault in file, the agent unless named: the text it replaces, its replacement
  # and the EUnit case of erx_connections_tests that must catch it.
  Mutant = Data.define(:file, :original, :replacement, :caught_by) do
    def initialize(original:, replacement:, caught_by:, file: AGENT) = super
  end
  INSTALL = "        {erx_origin, SystemId, {erx_facets_install, Tag, Name, Interface, Facet}} when is_integer(Tag) ->\n"
  MUTANTS = {
    'an agent that takes an installation with no interface as a files facet' =>
      Mutant.new(original: INSTALL,
                 replacement: "        {erx_origin, SystemId, {erx_facets_install, Tag, Name, Facet}} when is_integer(Tag) ->\n" \
                              "            records(minted_install(Env, Tag, Name, {5, Facet}), Held, Dropped);\n#{INSTALL}",
                 caught_by: 'untyped_facets_are_dropped'),
    'an agent that installs a facet whose interface is none' =>
      Mutant.new(original: 'case erx_facets:is_name(Name) andalso erx_facets:is_interface(Interface)',
                 replacement: 'case erx_facets:is_name(Name) andalso ' \
                              '(Interface =:= none orelse erx_facets:is_interface(Interface))',
                 caught_by: 'untyped_facets_are_dropped'),
    'a ready answer that keeps a facet with no valid interface' =>
      Mutant.new(original: 'is_atom(Name), erx_facets:is_interface(Interface),', replacement: 'is_atom(Name),',
                 caught_by: 'untyped_facets_are_dropped'),
    'an agent that installs a facet of a tree whose tree is no plain name' =>
      Mutant.new(file: FACETS, original: 'is_pid(Pid) andalso erx_9p_grammar:is_name(Tree) andalso',
                 replacement: 'is_pid(Pid) andalso is_binary(Tree) andalso', caught_by: 'installs')
  }.freeze

  def test_seeded_faults_are_caught
    runs = MUTANTS.map do |name, mutant|
      source = File.read(File.join(ROOT, mutant.file))
      assert_equal 1, source.scan(mutant.original).size, "mutant #{name} must edit exactly one place"
      seeded = source.sub(mutant.original) { mutant.replacement }
      Thread.new { [name, mutant, *seeded_run(mutant.file, seeded)] }
    end.map(&:value)
    runs.each do |name, mutant, output, ok|
      refute ok, "seeded fault not caught: #{name}"
      # Verbose EUnit names every case, so only the named case's failure line counts.
      assert_match(/#{mutant.caught_by}.*\*failed\*/, output, "seeded fault not caught by its case: #{name}")
    end
  end

  private

  # The agent cases' output and whether they passed, with seeded in place of file.
  def seeded_run(file, seeded)
    Dir.mktmpdir('erx-connections-seeded') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { file => seeded })
      area_nif(work)
      eunit_run(work, 'erx_connections_tests')
    end
  end

  def eunit(work, mod)
    output, ok = eunit_run(work, mod)
    assert ok, output
    assert_match(/(All \d+ tests passed|Test passed)/, output)
  end

  def eunit_run(work, mod)
    output, status = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval',
                                     "halt(case eunit:test(#{mod}, [verbose]) of ok -> 0; _ -> 1 end).",
                                     chdir: work, stdin_data: '')
    [output, status.success?]
  end

  # erx_area.so in work, against the headers of the emulator ERX_ERL runs.
  def area_nif(work)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Werror',
                                     *Erx::HostOs::NIF_LINK_FLAGS, '-DERX_AREA_LOADABLE',
                                     '-I', File.join(root, 'usr/include'),
                                     '-I', File.join(ROOT, 'otp/erts/emulator/nifs/erxos'),
                                     '-o', File.join(work, 'erx_area.so'), File.join(ROOT, AREA_STAND_IN),
                                     stdin_data: '')
    assert status.success?, output
  end
end
