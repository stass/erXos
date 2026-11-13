# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_trace_tests.erl, the check of erx:trace/1's Spec, the printed line
# and the trace process's pure decisions, on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), then each
# seed: a one-line flip of erx_trace.erl that the case it names must catch.
class ErxTraceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # erx compiled whole (ErlangBuild), and the suite; a seed replaces erx_trace.erl.
  TRACE = 'erlang/apps/erx/src/erx_trace.erl'
  TESTS = %w[test/erlang/erx_trace_tests.erl].freeze
  # A one-line flip of erx_trace.erl and the case that must catch it.
  Seed = Data.define(:original, :replacement, :test)
  SEEDS = {
    'bound' => Seed.new('selection([_ | _], 0) -> false;', 'selection([_ | _], 0) -> true;', 'badarg_test'),
    'unknown key' => Seed.new('Valid = maps:size(maps:without([select, frames, kernel], Spec)) =:= 0 andalso',
                              'Valid = true andalso', 'badarg_test'),
    'no selection' => Seed.new('true when Select =:= [], not Kernel -> error;', '', 'badarg_test'),
    'frames alone' => Seed.new('true when Select =:= [], Frames -> error;', '', 'badarg_test'),
    'no facet' => Seed.new("admit(_Request, none, _DomainOf) ->\n    {error, no_facet};", '', 'no_facet_test'),
    'kernel scope' => Seed.new("admit(\#{kernel := true}, Scope, _DomainOf) when Scope =/= all ->\n    {error, scope};",
                               '', 'scope_test'),
    'unknown domain' => Seed.new('lists:member(Domain, domains()) andalso in_scope(Domain, Scope).',
                                 'in_scope(Domain, Scope).', 'unknown_domain_test'),
    'escape' => Seed.new('<<(erx_text:escape_line(Text))/binary, $\n>>.',
                         '<<(unicode:characters_to_binary(Text))/binary, $\n>>.', 'escaped_line_test'),
    'window cap' => Seed.new('Window#window{credit = min(?WINDOW, Credit + ?ACK_EVERY)}.',
                             'Window#window{credit = Credit + ?ACK_EVERY}.', 'ack_bound_test'),
    'window shut' => Seed.new('{Send, Rest} = lists:split(min(Credit, length(Entries)), Entries),',
                              '{Send, Rest} = {Entries, []},', 'window_test'),
    'drops unreported' => Seed.new('[erx_tracer:dropped(Row, Count, Now) || {Row, Count} <- lists:sort(maps:to_list(Dropped))].',
                                   '[].', 'window_test'),
    'report count' => Seed.new('undelivered(#{row := Row, event := dropped, fields := #{count := Count}}, Window) -> ' \
                               'drop(Row, Count, Window);', '', 'report_wait_test'),
    'report ahead' => Seed.new('{Merger1, Late} = erx_tracer:hold(Merger, dropped_entries(Dropped, Now)),',
                               '{Merger1, Late} = {Merger, dropped_entries(Dropped, Now)},', 'report_test'),
    'report shut' => Seed.new("report(\#window{credit = 0} = Window, Merger, _Now) ->\n    {Window, Merger, []};",
                              '', 'report_test'),
    'batch bound' => Seed.new('buffer(Message, {Count, Messages}, Window) when Count < ?DRAIN ->',
                              'buffer(Message, {Count, Messages}, Window) ->', 'buffer_test'),
    'forged session' => Seed.new('  when is_pid(Pid), is_integer(Time),', '  when true,', 'classify_test'),
    'foreign stop' => Seed.new("classify({erx_trace_stop, Ref}, \#{ref := Ref}) ->",
                               'classify({erx_trace_stop, _Ref}, _Expect) ->', 'classify_test'),
    'full read' => Seed.new("{length(Records) =:= ?READ_MAX, Cursors\#{Source := Next}};",
                            "{false, Cursors\#{Source := Next}};", 'cursor_test'),
    'refused ring' => Seed.new('{false, maps:remove(Source, Cursors)}.', '{false, Cursors}.', 'cursor_test')
  }.freeze

  def test_every_case_passes
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  SEEDS.each do |name, seed|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, TRACE))
      assert_equal 1, source.scan(seed.original).size, "the seed's text is not in erx_trace.erl once"
      output, status = eunit({ TRACE => source.sub(seed.original, seed.replacement) })
      refute status.success?, "#{name}: every case passed"
      # One line: the named case itself failed, not merely a case after it.
      assert_match(/^\s*erx_trace_tests: #{seed.test}\.\.\.[^\n]*\*failed\*/, output)
    end
  end

  private

  # Compiles erx, with a seeded erx_trace.erl in replaced, and the suite, and runs it.
  def eunit(replaced)
    Dir.mktmpdir('erx-trace-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_trace_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
