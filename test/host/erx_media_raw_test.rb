# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_media_raw_tests.erl, the EUnit cases of the drives' raw sectors
# (docs/design-drives.md, "Raw sectors"): the barrier's state machine over every event
# sequence up to its bound, a request's plan, and the raw tree and its raw process over a
# fake window, against erx and erx_media compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then it seeds the faults the design's
# test row names, each of which a named case must catch.
class ErxMediaRawTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  MODULES = %w[erx_media_raw_tests].freeze
  # The media suites whose fixtures the raw cases call: the fake facet, the MBR, the
  # stand-in supervisor.
  HELPERS = %w[erx_media_volume_tests erx_media_tree_tests erx_media_volume_write_tests erx_fat_alloc_tests].freeze
  TESTS = (MODULES + HELPERS).map { |name| "test/erlang/#{name}.erl" }.freeze
  BARRIER = 'erlang/apps/erx_media/src/erx_media_raw_barrier.erl'
  RAW = 'erlang/apps/erx_media/src/erx_media_raw.erl'
  DRIVE = 'erlang/apps/erx_media/src/erx_media_drive.erl'

  Fault = Data.define(:name, :path, :from, :to, :caught_by)
  FAULTS = [
    Fault.new(name: 'the barrier flushing with no write sent', path: BARRIER,
              from: 'held = Held, wrote = false} = B) when Held =/= [] ->',
              to: 'held = Held, wrote = false} = B) when Held =:= [], Held =/= [] ->',
              caught_by: 'a flush that cannot flush refuses the open'),
    Fault.new(name: 'a refused open handing back its volumes itself', path: RAW,
              from: "    gen_server:reply(From, {error, Errno}),\n    left(Open, State).",
              to: "    gen_server:reply(From, {error, Errno}),\n    Barrier = maps:get(barrier, State),\n" \
                  "    left(Open, act({hand_back, erx_media_raw_barrier:holds(Barrier)}, State)).",
              caught_by: 'a refused open hands nothing back'),
    Fault.new(name: 'the grant\'s end not counted as a close', path: RAW,
              from: 'when map_get(Grant, Grants) =:= Monitor ->',
              to: 'when map_get(Grant, Grants) =:= Monitor, false ->',
              caught_by: 'a grant\'s end is a close behind its held write'),
    Fault.new(name: 'the volumes returned without waiting for unanswered writes', path: BARRIER,
              from: 'test(#barrier{writers = 0, sent = 0, held = Held, wrote = true} = B) when Held =/= [] ->',
              to: 'test(#barrier{writers = 0, held = Held, wrote = true} = B) when Held =/= [] ->',
              caught_by: 'a grant\'s end is a close behind its held write'),
    Fault.new(name: 'the placement skipped for sN.data', path: RAW,
              from: '        {ok, Lba} -> Lba;',
              to: '        {ok, _Lba} -> Sector;',
              caught_by: 'a writing open takes its volume until its close'),
    Fault.new(name: 'the open answered before the finish of its volume', path: DRIVE,
              from: '    Answer = first_failure(answers([gen_server:send_request(Pid, finish) || {_N, Pid} <- Finished])),',
              to: '    Answer = ok,',
              caught_by: 'a refused open hands nothing back')
  ].freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.path))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.path => original.sub(fault.from) { fault.to } })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}.*?\*failed\*/m, output, fault.name)
    end
  end

  private

  def eunit(replaced)
    Dir.mktmpdir('erx-media-raw-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{MODULES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
