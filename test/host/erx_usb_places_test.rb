# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_places_prop.erl, the places row of docs/design-usb.md's host
# tests: the USB domain's places, erx_usb_places_sup, its input numbers' streams read
# through a real erx_fs grant of its input tree, against a model over attach, detach,
# crash, halted pipe and restart sequences, on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies), against the sources as they are and against each seeded
# fault, where the named case must fail.
class ErxUsbPlacesTest < Minitest::Test
  APPLICATIONS = %w[erx erx_blk erx_usb].freeze
  # The grammar is generated into OTP's preloaded sources, outside the applications, so it
  # is compiled with the cases; the stand-ins replace the erx modules the grant calls.
  TESTS = %w[
    build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl
    test/erlang/erx_usb_places_prop.erl
    test/erlang/erx_usb_drives_prop.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
  ].freeze
  DEADLINE_SECONDS = '300'
  STREAM = 'erlang/apps/erx_usb/src/erx_usb_input_stream.erl'
  PROPERTY = 'places_hold_under_random_sequences_test_'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'an occupant that crashes frees its number without release',
             module_path: STREAM,
             anchor: "handle_info({'DOWN', Monitor, process, _, _}, #stream{occupant = {_, Monitor}} = S) ->\n" \
                     "    {noreply, ended(S)};\n",
             replacement: "handle_info({'DOWN', Monitor, process, _, normal}, #stream{occupant = {_, Monitor}} = S) ->\n" \
                          "    {noreply, ended(S)};\n" \
                          "handle_info({'DOWN', Monitor, process, _, _}, #stream{occupant = {_, Monitor}} = S) ->\n" \
                          "    {noreply, serve(S#stream{occupant = none, pending = none})};\n",
             catching_case: PROPERTY),
    Seed.new(fault: 'a write taken past one read\'s worth',
             module_path: STREAM,
             anchor: "offer(From, Bytes, #stream{buffer = Buffer} = S)\n" \
                     "  when byte_size(Buffer) + byte_size(Bytes) =< ?ERX_P9_IO_MAX ->\n",
             replacement: "offer(From, Bytes, #stream{buffer = Buffer} = S) when is_binary(Bytes) ->\n",
             catching_case: PROPERTY),
    Seed.new(fault: "a start that counts an ended occupant whose 'DOWN' is not yet taken",
             module_path: STREAM,
             anchor: '    S = take_ended(S0),',
             replacement: '    S = S0,',
             catching_case: 'a_start_ahead_of_the_end_still_finds_release_test'),
    Seed.new(fault: 'a read that ends inside a record',
             module_path: STREAM,
             anchor: '            Size = min(Count - Count rem erx_input_codec:size(), byte_size(Buffer)),',
             replacement: '            Size = min(Count, byte_size(Buffer)),',
             catching_case: 'reads_take_whole_records_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The cases run with the logger off, so the crashes the seeds cause keep each case's
  # verdict on its line.
  def run_cases(replaced)
    Dir.mktmpdir('erx-usb-places-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_usb_places_prop, erx_usb_drives_prop], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
