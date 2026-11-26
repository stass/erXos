# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_file_remote_tests.erl, the EUnit cases of erx_file_remote's
# exchange with a server (docs/design-files.md, Erlang clients), against erx_file_remote
# and the generated grammar compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), and against each seeded
# fault below, where the named case must fail: a client that takes a reply only bare,
# which no server of another domain can answer, and one that takes whatever an envelope
# holds at the alias's place, another alias's reply included, each in the one pattern
# of an enveloped reply that every take of either half matches. The fuzz target,
# tools/fuzz/erx_file_remote.rb, drives the same exchange with random messages.
class ErxFileRemoteReplyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  CLIENT = 'otp/erts/preloaded/src/erx_file_remote.erl'
  SOURCES = [CLIENT, 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl',
             'test/erlang/erx_file_remote_tests.erl'].freeze
  INCLUDES = %w[otp/lib/kernel/include build/gen/erlang/apps/erx/include].flat_map { |dir| ['-I', File.join(ROOT, dir)] }.freeze
  # The envelope's pattern, which each fault changes.
  ENVELOPED = '-define(ENVELOPED(Alias, Reply), {erx_origin, _, {erx_9p, Alias, Reply}}).'

  Fault = Data.define(:name, :to, :caught_by)
  FAULTS = [
    Fault.new(name: 'a client that takes a reply only bare', to: '-define(ENVELOPED(Alias, Reply), {erx_origin, _, {erx_9p, Alias, Reply}, bare_only}).',
              caught_by: 'reply_from_another_domain_is_taken_in_its_envelope_test'),
    Fault.new(name: "a client that takes any alias's reply out of an envelope",
              to: '-define(ENVELOPED(Alias, Reply), {erx_origin, _, {erx_9p, _, Reply}}).',
              caught_by: 'only_a_reply_at_the_alias_in_one_envelope_is_taken_test')
  ].freeze
  # Stock's prim_file has no erx_fid/0, so the client compiles with a stand-in that
  # hands out fresh fids.
  FID = "fid() ->\n    prim_file:erx_fid().\n"
  STAND_IN_FID = "fid() ->\n    erlang:unique_integer([positive]).\n"
  # Seeded faults of a native program's open, of the seek rule and of the frame bound:
  # the text replaced, its replacement and the case that must fail.
  TextFault = Data.define(:name, :from, :to, :caught_by)
  TEXT_FAULTS = [
    TextFault.new(name: "an lopen's eloop under O_NOFOLLOW answered as it is",
                  from: 'unfollowed({error, eloop}, Flags) when Flags band ?ERX_P9_O_NOFOLLOW =/= 0 -> {error, emlink};',
                  to: 'unfollowed({error, eloop}, Flags) when Flags < 0 -> {error, emlink};',
                  caught_by: 'nofollow_refuses_a_last_link_test_'),
    TextFault.new(name: 'an lopen under O_NOFOLLOW that follows a last link',
                  from: 'last_mode(true) -> nofollow;', to: 'last_mode(true) -> follow;',
                  caught_by: 'nofollow_refuses_a_last_link_test_'),
    TextFault.new(name: "an lcreate under O_NOFOLLOW that follows a last link",
                  from: 'unfollowing(Flags) when Flags band ?ERX_P9_O_NOFOLLOW =/= 0 -> emlink;',
                  to: 'unfollowing(Flags) when Flags < 0 -> emlink;',
                  caught_by: 'nofollow_refuses_a_last_link_test_'),
    TextFault.new(name: 'O_DIRECTORY dropped',
                  from: 'directory => Flags band ?ERX_P9_O_DIRECTORY =/= 0, type_check => false',
                  to: 'directory => false, type_check => false',
                  caught_by: 'directory_opens_only_a_directory_test_'),
    TextFault.new(name: 'a seek past off_t admitted',
                  from: 'seek_to(Base, Offset) when Base + Offset > ?ERX_OFF_MAX -> {error, eoverflow};',
                  to: 'seek_to(Base, Offset) when Base + Offset > ?ERX_OFF_MAX + 1 -> {error, eoverflow};',
                  caught_by: 'seek_to_follows_freebsd_test_'),
    TextFault.new(name: 'the frame bound removed, so a request past it is sent and dropped',
                  from: 'erlang:external_size(Message) > ?ERX_FILES_MAX_FRAME_MIN orelse oversized(Addressed).',
                  to: 'erlang:external_size(Message) < 0 orelse oversized(Addressed).',
                  caught_by: 'write_past_the_frame_bound_is_refused_before_it_is_sent_test_'),
    TextFault.new(name: 'a message exactly at the frame bound refused',
                  from: 'erlang:external_size(Message) > ?ERX_FILES_MAX_FRAME_MIN orelse oversized(Addressed).',
                  to: 'erlang:external_size(Message) >= ?ERX_FILES_MAX_FRAME_MIN orelse oversized(Addressed).',
                  caught_by: 'write_past_the_frame_bound_is_refused_before_it_is_sent_test_')
  ].freeze

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CLIENT)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      source = File.read(File.join(ROOT, CLIENT))
      assert_equal 1, source.scan(ENVELOPED).size, "#{fault.name}: the pattern not found once"
      output, status = eunit(source.gsub(ENVELOPED) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(?:failed|timed out)\*/, output, fault.name)
    end
  end

  TEXT_FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_text_fault_#{index}_is_caught") do
      source = File.read(File.join(ROOT, CLIENT))
      assert_equal 1, source.scan(fault.from).size, "#{fault.name}: the text not found once"
      output, status = eunit(source.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(?:failed|timed out)\*/, output, fault.name)
    end
  end

  private

  # Compiles the client from client_text, with the grammar and the cases, and runs them.
  def eunit(client_text)
    Dir.mktmpdir('erx-file-remote-reply') do |work|
      client = File.join(work, File.basename(CLIENT))
      raise 'the client has no fid/0 to stand in for' unless client_text.include?(FID)

      File.write(client, client_text.sub(FID) { STAND_IN_FID })
      sources = [client, *SOURCES.drop(1).map { |path| File.join(ROOT, path) }]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', *INCLUDES, '-o', work, *sources, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_file_remote_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
