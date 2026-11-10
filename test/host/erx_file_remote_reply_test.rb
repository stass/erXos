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
# holds at the alias's place, another alias's reply included. The fuzz target,
# tools/fuzz/erx_file_remote.rb, drives the same exchange with random messages.
class ErxFileRemoteReplyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  CLIENT = 'otp/erts/preloaded/src/erx_file_remote.erl'
  SOURCES = [CLIENT, 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl',
             'test/erlang/erx_file_remote_tests.erl'].freeze
  INCLUDES = %w[otp/lib/kernel/include build/gen/erlang/apps/erx/include].flat_map { |dir| ['-I', File.join(ROOT, dir)] }.freeze
  # The envelope's clauses, while the server lives and once it has ended, which each
  # fault changes alike.
  ENVELOPED = "        {erx_origin, _, {erx_9p, Alias, Reply}} -> {reply, Reply}"

  Fault = Data.define(:name, :to, :caught_by)
  FAULTS = [
    Fault.new(name: 'a client that takes a reply only bare', to: "        {erx_origin, _, {erx_9p, Alias, Reply}} when false -> {reply, Reply}",
              caught_by: 'reply_from_another_domain_is_taken_in_its_envelope_test'),
    Fault.new(name: "a client that takes any alias's reply out of an envelope",
              to: "        {erx_origin, _, {erx_9p, _, Reply}} -> {reply, Reply}",
              caught_by: 'only_a_reply_at_the_alias_in_one_envelope_is_taken_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CLIENT)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      source = File.read(File.join(ROOT, CLIENT))
      assert_equal 2, source.scan(ENVELOPED).size, "#{fault.name}: the two clauses not found"
      output, status = eunit(source.gsub(ENVELOPED) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(?:failed|timed out)\*/, output, fault.name)
    end
  end

  private

  # Compiles the client from client_text, with the grammar and the cases, and runs them.
  def eunit(client_text)
    Dir.mktmpdir('erx-file-remote-reply') do |work|
      client = File.join(work, File.basename(CLIENT))
      File.write(client, client_text)
      sources = [client, *SOURCES.drop(1).map { |path| File.join(ROOT, path) }]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', *INCLUDES, '-o', work, *sources, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_file_remote_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
