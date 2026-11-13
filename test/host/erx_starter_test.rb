# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/apps'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/manifest_context'

# The start service's processes (docs/design-apps.md, "Verification and testing"):
# test/erlang/erx_starter_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies) over a stub domain service, against the sources as they are and
# against each seeded fault below, where the named case must fail.
class ErxStarterTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APP = 'erlang/apps/erx_starter/src'
  # erx_domain holds erx_ident (the core reads names with it) and the keeper's client of
  # the domain service; erx_files holds erx_fs, the behaviour of erx_starter_fs.
  APPLICATIONS = %w[erx erx_files erx_domain erx_starter].freeze
  TESTS = %w[test/erlang/erx_starter_tests.erl test/erlang/erx_starter_fs_tests.erl].freeze

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
              from: '{ok, _Row} -> erx_starter_sup:stop_row(Name);', to: '{ok, _Row} -> erx_starter_sup:stop(Name);',
              caught_by: 'a_stopped_row_stays_stopped_across_a_restart'),
    Fault.new(name: 'a helper that leaves the session of a keeper that ended',
              file: "#{APP}/erx_starter_keeper.erl",
              from: "{'EXIT', Keeper, _} -> exit(Pid, abandoned)", to: "{'EXIT', Keeper, _} -> ok",
              caught_by: 'a_keeper_stopped_while_its_start_is_pending_ends_the_session'),
    Fault.new(name: 'a table that reconciles with no stopped marks',
              file: "#{APP}/erx_starter.erl",
              from: 'erx_start_table:reconcile(Held, Stopped, After)',
              to: 'erx_start_table:reconcile(Held, Stopped -- Stopped, After)',
              caught_by: 'a_stopped_row_stays_stopped_when_its_settings_change'),
    Fault.new(name: 'a stop that ends the row before it marks it',
              file: "#{APP}/erx_starter_sup.erl",
              from: "ok = erx_starter_records:mark(Name),\n    stop(Name).",
              to: "ok = stop(Name),\n    erx_starter_records:mark(Name).",
              caught_by: 'stop_marks_the_row_before_it_ends_it'),
    Fault.new(name: 'a start that leaves the stopped mark',
              file: "#{APP}/erx_starter_sup.erl",
              from: '    erx_starter_records:unmark(Name).', to: '    ok.',
              caught_by: 'enable_starts_a_stopped_row_and_clears_its_mark'),
    Fault.new(name: 'a row with no supervisor shown stopped whether marked or not',
              file: "#{APP}/erx_starter.erl",
              from: 'true -> stopped;', to: 'true -> stopped; _ when Stopped =:= [] -> stopped;',
              caught_by: 'a_row_neither_held_nor_marked_is_starting'),
    Fault.new(name: "a records process whose crash leaves the keepers' branch and its sessions",
              file: "#{APP}/erx_starter_sup.erl",
              from: 'restart => temporary, significant => true', to: 'restart => permanent',
              caught_by: 'a_crash_of_the_records_ends_every_session_and_record'),
    Fault.new(name: 'a start that starts the row before it clears the mark',
              file: "#{APP}/erx_starter_sup.erl",
              from: "ok = clear(Name),\n    " \
                    'supervisor:start_child(?KEEPERS, #{id => {row, Name}, start => {erx_starter_row, start_link, [Row]},' \
                    "\n#{' ' * 39}restart => transient, type => supervisor, shutdown => infinity}).",
              to: 'Started = supervisor:start_child(?KEEPERS, #{id => {row, Name}, ' \
                  'start => {erx_starter_row, start_link, [Row]}, restart => transient, ' \
                  "type => supervisor, shutdown => infinity}),\n    ok = clear(Name),\n    Started.",
              caught_by: 'start_clears_the_mark_before_it_starts_the_row'),
    Fault.new(name: 'an enable that clears the mark after the table is made from its text',
              file: "#{APP}/erx_starter.erl",
              from: "ok = clear_for_enable(Command),\n    Applied = apply_text(Text, State),",
              to: "Applied = apply_text(Text, State),\n    ok = clear_for_enable(Command),",
              caught_by: 'enable_clears_the_mark_before_the_table_is_made'),
    Fault.new(name: 'a table that leaves a held row that is marked stopped',
              file: "#{APP}/erx_start_table.erl",
              from: 'decide({_Run, _Kept}, true, _Is) -> stop;', to: 'decide({_Run, _Kept}, true, _Is) -> keep;',
              caught_by: 'the_next_table_completes_a_stop_cut_short'),
    Fault.new(name: 'an rc.conf process that carries out the write of a process that did not read last',
              file: "#{APP}/erx_starter_rc.erl",
              from: "handle_call({write, _Directory, _Text}, _From, State) ->\n    {reply, {error, superseded}, State}.",
              to: "handle_call({write, Directory, Text}, _From, State) ->\n    {reply, write_file(Directory, Text), State}.",
              caught_by: 'a_write_from_a_process_that_did_not_read_last_is_refused'),
    Fault.new(name: "a table's read of rc.conf in a process of its own, beside the ended table's write",
              file: "#{APP}/erx_starter_rc.erl",
              from: 'gen_server:send_request(?MODULE, {read, Directory})',
              to: 'gen_server:send_request(element(2, gen_server:start(?MODULE, [], [])), {read, Directory})',
              caught_by: 'a_write_of_an_ended_table_lands_before_the_next_table_reads'),
    Fault.new(name: "a first read of rc.conf that does not wait for the system domain's namespace",
              file: "#{APP}/erx_starter.erl",
              from: '{noreply, Recorded#{reader := {namespace, erx_domain:system_namespace()}}}',
              to: '{noreply, read(Recorded)}',
              caught_by: 'no_row_starts_before_the_namespace_is_in_place'),
    Fault.new(name: 'a manifest table whose displays are every service a template is granted',
              file: "#{APP}/erx_starter.erl",
              from: 'Windows(Index)],', to: 'is_function(Windows)],',
              caught_by: 'only_a_granted_windows_service_is_a_display'),
    Fault.new(name: 'a manifest table that reads the interface of the service after the granted one',
              file: "#{APP}/erx_starter.erl",
              from: 'lists:nth(Index + 1, ServiceRecords)', to: 'lists:nth(Index + 2, ServiceRecords)',
              caught_by: 'only_a_granted_windows_service_is_a_display')
  ].freeze

  # A windows service of the web domain, with its display record, granted to the apps
  # suite's template: the one display clock may name beside its data grant.
  SCREEN = <<~ROWS
    service screen
      server @domain.web
      interface windows
    display screen
      policy single
      idle_dim_s 60
      idle_off_s 600
    facet clock_screen
      grantee @session.#{Erx::Apps::PRINCIPAL}
      service @service.screen
      operations none
      max_request 1
      in_flight 1
      reductions 1
      period_ns 1
      max_heap_size 1
      parameter pixels 4096
  ROWS

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

  # The apps QEMU suite's manifest (Erx::Apps.manifest, its kept boot) with SCREEN,
  # admitted against the machine that suite boots and a fixture archive, for
  # erx_starter:manifest_table/1's case: clock's template is granted data, a files
  # service, and screen, a windows service. Packed once, since every run reads it.
  def self.packed_manifest
    @packed_manifest ||= begin
      codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
      platform = Erx::MediumBoot.machine(Erx::Platform.development(ROOT)).record
      arguments = ManifestContextFixture.archive_arguments(codec, boots: %w[app clock display network session storage web])
      source = Erx::Apps.manifest(File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt')),
                                  boot: :kept) + SCREEN
      Erx::Manifest.admit(source: source, codec: codec,
                          context: Erx::Manifest::Context.new(**arguments, platform: platform),
                          planner: ManifestContextFixture.accepting_planner).bytes
    end
  end

  private

  # Compiles the applications and the suites, each source of replaced by its text there,
  # and runs the suite mod.
  def eunit(replaced, mod: 'erx_starter_tests')
    Dir.mktmpdir('erx-starter-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      manifest = File.join(work, 'manifest.bin')
      File.binwrite(manifest, self.class.packed_manifest)
      Open3.capture2e({ 'ERX_STARTER_MANIFEST' => manifest },
                      'gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test(#{mod}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
