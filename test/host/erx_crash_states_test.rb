# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'
require_relative '../../tools/lib/erx/fsimg'
require_relative '../../tools/lib/erx/output_directory'

# Runs the crash-state generator's EUnit cases (test/erlang/erx_crash_states_tests.erl)
# and the landing gate's FAT suite (erx_crash_fat_tests.erl, docs/design-crash-states.md)
# against erx_fat and erx_media compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies), over the FAT16 and FAT32 volumes fsimg makes
# (FatVolumes), and seeds the faults the design's Tests table names for them. Every
# file a run writes, the volumes and the failure records, lands under build/test/
# crash-states, prepared by Erx::OutputDirectory.
class ErxCrashStatesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  BUILD = File.join(ROOT, 'build')
  OUTPUT = 'test/crash-states'
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  MODULES = %w[erx_ram_window erx_crash_states erx_fs_model erx_crash_workloads erx_crash_run
               erx_crash_states_tests erx_crash_fat_tests].freeze
  TESTS = MODULES.map { |name| "test/erlang/#{name}.erl" }.freeze
  VOLUME = 'erlang/apps/erx_media/src/erx_media_volume.erl'
  STATES = 'test/erlang/erx_crash_states.erl'
  MODEL = 'test/erlang/erx_fs_model.erl'
  RUN = 'test/erlang/erx_crash_run.erl'
  PLAN = 'erlang/apps/erx_fat/src/erx_fat_plan.erl'
  STEP_LOOP = "apply([{_Step, Images} | Rest], Write, Flush) ->\n" \
              "    case written(Images, Write) of\n" \
              "        ok ->\n" \
              "            case Flush() of\n"

  # shows, when set, is the failing step the run must print, so a fault that breaks the
  # recording or crashes a check does not pass for the one it seeds.
  Fault = Data.define(:name, :path, :from, :to, :caught_by, :shows) do
    def initialize(shows: nil, **fields) = super
  end

  # Each fault replaces one passage of a module; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'an fsync answered without committing its batch', path: VOLUME,
              from: "request(fsync, State) ->\n    {ok, committed(State)};", to: "request(fsync, State) ->\n    {ok, State};",
              caught_by: 'fat_seq_1_test_', shows: /choice .*: obligations: /),
    Fault.new(name: "the flush after erx_fat_dir's preparation step dropped", path: PLAN, from: STEP_LOOP,
              to: STEP_LOOP.sub('{_Step, Images}', '{Step, Images}')
                           .sub('case Flush() of', 'case if Step =:= preparation -> ok; true -> Flush() end of'),
              caught_by: 'fat_seq_1_test_', shows: /choice .*: ownership: /),
    Fault.new(name: "a publication write sent before the preparation step's flush", path: VOLUME,
              from: "applied(Plan, \#{proxy := Proxy, volume := Volume}) ->\n",
              to: <<~'ERL',
                applied(Planned, #{proxy := Proxy, volume := Volume}) ->
                    Plan = case lists:keyfind(publication, 1, Planned) of
                               {publication, [Early | Rest]} ->
                                   [case S of {preparation, W} -> {preparation, W ++ [Early]};
                                              {publication, _} -> {publication, Rest}; _ -> S end || S <- Planned];
                               _ -> Planned
                           end,
              ERL
              caught_by: 'fat_seq_1_test_', shows: /choice .*: obligations: /),
    Fault.new(name: 'the model judging every path by its acknowledged value alone', path: MODEL,
              from: '[{acked, maps:get(Path, Acked, absent)} | Later].',
              to: '[{acked, maps:get(Path, Acked, absent)} | lists:sublist(Later, 0)].',
              caught_by: 'fat_seq_1_test_'),
    Fault.new(name: 'a generator that yields only the in-order cuts', path: STATES,
              from: 'true -> {exhaustive, every_choice(Sizes)};', to: 'true -> _ = every_choice(Sizes), {exhaustive, in_order_cuts(Epoch)};',
              caught_by: 'state_counts_test'),
    Fault.new(name: "a failed flush counted as an epoch's end", path: STATES,
              from: 'epochs([{Pos, {flush, ok}} | Rest]', to: 'epochs([{Pos, {flush, _}} | Rest]',
              caught_by: 'epochs_test'),
    Fault.new(name: 'the replayed choice applied to the image after its epoch', path: STATES,
              from: '[#{start := Start, values := Values}] = [E ||', to: %q([#{'end' := Start, values := Values}] = [E ||),
              caught_by: 'a_failing_state_replays_byte_for_byte_test'),
    Fault.new(name: "obligations taken only at the epoch's end", path: RUN,
              from: '[lists:last(Before) | [{Pos, O} || {Pos, O} <- After, Pos < End]].',
              to: '[lists:last(Before ++ [{Pos, O} || {Pos, O} <- After, Pos < End])].',
              caught_by: 'a_stray_write_fails_at_its_earliest_moment_test'),
    Fault.new(name: 'a sampled epoch reported as exhaustive', path: STATES,
              from: '{{sampled, length(Choices), Count, Seed, version()}, Choices}.', to: '_ = Count, {exhaustive, Choices}.',
              caught_by: 'a_sampled_epoch_says_so_test')
  ].freeze

  def self.images
    @images ||= Erx::OutputDirectory.fresh(root: BUILD, path: File.join(OUTPUT, 'images')).tap do |directory|
      FatVolumes.write(directory, root: ROOT)
    end
  end

  def test_the_cases_pass
    output, status = eunit({}, 'clean')
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
    puts output.lines.grep(/^crash states|^fat(16|32)\.img/).join
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.path))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.path => original.sub(fault.from) { fault.to } }, "fault-#{index}", fault.caught_by)
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}.*?\*failed\*/m, output, fault.name)
      assert_match(fault.shows, output, fault.name) if fault.shows
    end
  end

  private

  # Compiles the applications with the replaced module texts, and the suites, and runs
  # them, or only the case named, with a fresh output directory named run.
  def eunit(replaced, run, only = nil)
    out = Erx::OutputDirectory.fresh(root: BUILD, path: File.join(OUTPUT, run))
    %w[unit seq-1 seq-2].each { |name| Erx::OutputDirectory.prepare(root: BUILD, path: File.join(OUTPUT, run, name)) }
    Dir.mktmpdir('erx-crash-states-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images, 'ERX_CRASH_OUT' => out },
                      'gtimeout', '-k', '10', '1800', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      ErlangBuild.eunit_eval(ErlangBuild.eunit_spec(TESTS, only)), chdir: work, stdin_data: '')
    end
  end
end
