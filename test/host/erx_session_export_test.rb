# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The fixed tree of the session's export (docs/design-files.md, "Narrowing for a
# program"): test/erlang/erx_session_export_tests.erl runs on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies) against the sources as they are, and against
# each seeded fault below, where the named case must fail. Stock's emulator has no
# erx_bytes:entropy/1, so every case hands the tree a stand-in generator.
class ErxSessionExportTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the suite exercises, compiled whole (ErlangBuild), and the suite.
  APPLICATIONS = %w[erx_session].freeze
  TESTS = %w[test/erlang/stand_in/erx_win.erl
             test/erlang/stand_in/erx_draw_conn.erl test/erlang/erx_session_export_tests.erl].freeze
  TREE = 'erlang/apps/erx_session/src/erx_session_export.erl'

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of the tree; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'a read-only file opened for writing',
              from: '{write, _, true} -> handle(Node, write, Flags, Fs);',
              to: '{write, _, _} -> handle(Node, write, Flags, Fs);',
              caught_by: 'the_read_only_files_refuse_writing_test'),
    Fault.new(name: 'a generator read past its bound',
              from: "{ok, << <<(Entropy(Size))/binary>> || Size <- Sizes >>}",
              to: '{ok, Entropy(Count)}',
              caught_by: 'urandom_reads_the_generator_within_its_bound_test'),
    Fault.new(name: 'a kbd or mouse read that waits for its record inside the callback',
              from: "read({File, _}, Offset, Count, \#{window := \#{conn := Conn}}) when File =:= kbd; File =:= mouse ->\n" \
                    "    %% A read that waits for a record waits at the draw connection, its keeper.\n" \
                    "    {wait, Conn, {read, File, Offset, Count}};\n",
              to: '',
              caught_by: 'kbd_and_mouse_reads_wait_at_the_connection_test'),
    Fault.new(name: 'a ctl read that answers a short count',
              from: '{ok, Text} when byte_size(Text) > Count -> {error, einval};',
              to: '{ok, Text} when Count < 0 -> {error, einval};',
              caught_by: 'ctl_reads_whole_at_offset_zero_and_never_opens_for_writing_test'),
    Fault.new(name: 'an export that opens /dev/tty',
              from: "open(tty, _Flags, _Fs) ->\n    {error, enxio};\n",
              to: '',
              caught_by: 'the_export_answers_an_lopen_of_tty_with_enxio_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, TREE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ TREE => original.sub(fault.from) { fault.to } })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name.
      verdict = /#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_session_export_tests: ).)*?\*(?:failed|timed out)\*/m
      assert_match(verdict, output, fault.name)
    end
  end

  private

  # Compiles the sources, with any replaced by the given text, and runs the suite.
  def eunit(replaced)
    Dir.mktmpdir('erx-session-export-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      run = 'halt(case eunit:test(erx_session_export_tests, [verbose]) of ok -> 0; _ -> 1 end)'
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', run, chdir: work, stdin_data: '')
    end
  end
end
