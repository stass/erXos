# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_tracer_tests.erl on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies) against erx_tracer and the checked-in generated erx_abi_events and
# erx_schema, then each seed: a one-line flip of erx_tracer.erl that the case it names
# must catch.
class ErxTracerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erx_tracer.erl generated/erx_abi_events.erl generated/erx_schema.erl]
            .map { |name| File.join(ROOT, 'erlang/apps/erx/src', name) }.freeze
  TRACER = SOURCES.first
  # A one-line flip of erx_tracer.erl and the case that must catch it.
  Seed = Data.define(:original, :replacement, :test)
  SEEDS = {
    'order' => Seed.new('before(#{time := A}, #{time := B}) -> A =< B.', 'before(#{time := A}, #{time := B}) -> A >= B.',
                        'ordering_test'),
    'session batch' => Seed.new("{erts, _Domain} -> {Next, Time};", "{erts, _Domain} -> {Time, none};",
                                'ordering_test'),
    'per source' => Seed.new('Shown =/= none andalso Shown >= Time', 'Shown =:= none orelse Shown >= Time',
                             'per_source_test'),
    'monotone' => Seed.new('later(Shown, Time) -> max(Shown, Time).', 'later(_Shown, Time) -> Time.',
                           'shown_time_is_monotone_test'),
    'hold' => Seed.new('Now - Time >= ?HOLD_NS orelse', 'Now - Time > ?HOLD_NS orelse', 'hold_test'),
    'late' => Seed.new('[Entry#{late := true} || Entry <- Late]}', '[Entry || Entry <- Late]}', 'late_test'),
    'conversion' => Seed.new('Monotonic + (PairClock - PairMonotonic).', 'Monotonic + (PairMonotonic - PairClock).',
                             'clock_conversion_test'),
    'unknown' => Seed.new('entry(Time, Row, {unknown, Event}, Base, false);', 'entry(Time, Row, unknown, Base, false);',
                          'unknown_and_named_events_test'),
    'overwritten' => Seed.new('overwritten(_Row, 0, _Entries, _Now) -> [];',
                              'overwritten(_Row, _Count, _Entries, _Now) -> [];', 'overwritten_test'),
    'unsupported' => Seed.new('{kernel, true} -> {Rest#merger{reported = [Row | Reported]}, [entry(Now, Row, unsupported, #{}, false)]};',
                              '{kernel, true} -> {Rest, []};', 'kernel_unsupported_test'),
    'once' => Seed.new('maps:is_key(Source, Waiting) andalso not lists:member(Row, Reported)', 'true',
                       'kernel_unsupported_test'),
    'refused waited' => Seed.new("Rest = Merger#merger{waiting = maps:remove(Source, Waiting)},\n    case maps:is_key(Source, Waiting) of",
                                 "Rest = Merger,\n    case maps:is_key(Source, Waiting) of", 'refused_read_test'),
    'refused shown' => Seed.new('true -> {Rest, [entry(Now, row(Source), error, refusal_fields(Source, Status), false)]};',
                                'true -> {Rest, []};', 'refused_read_test')
  }.freeze

  def test_every_case_passes
    output, status = eunit(File.read(TRACER), strict: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  SEEDS.each do |name, seed|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(TRACER)
      assert_equal 1, source.scan(seed.original).size, "the seed's text is not in erx_tracer.erl once"
      output, status = eunit(source.sub(seed.original, seed.replacement), strict: false)
      refute status.success?, "#{name}: every case passed"
      # One line: the named case itself failed, not merely a case after it.
      assert_match(/^\s*erx_tracer_tests: #{seed.test}\.\.\.[^\n]*\*failed\*/, output)
    end
  end

  private

  # A seed may leave a variable unused or a clause unreachable, so only the
  # unseeded module compiles with -Werror.
  def eunit(tracer, strict:)
    Dir.mktmpdir('erx-tracer-test') do |work|
      File.write(File.join(work, 'erx_tracer.erl'), tracer)
      sources = [File.join(work, 'erx_tracer.erl'), *SOURCES.drop(1), File.join(ROOT, 'test/erlang/erx_tracer_tests.erl')]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *(strict ? ['-Werror'] : []), '-o', work, *sources, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_tracer_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
