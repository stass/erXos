# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'stringio'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/passphrase_hash'

# The development passphrase checker (docs/design-login.md, "The passphrase check")
# and root's passphrase line (docs/design-ssh.md, "Root's passphrase on the medium"):
# test/erlang/erx_passphrase_tests.erl runs on stock's emulator, with erx_bytes'
# host stand-in, against the modules as they are and against each seeded fault below,
# where the named case must fail; and the host tool's line against FreeBSD 14.3.0's
# crypt-sha256.c vectors, which the Erlang derivation checks too.
class ErxPassphraseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_files erx_domain].freeze
  TESTS = %w[test/erlang/erx_passphrase_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  CHECK = 'erlang/apps/erx_domain/src/erx_passphrase_check.erl'
  LINE = 'erlang/apps/erx/src/erx_boot_passphrase.erl'
  HASH = 'erlang/apps/erx/src/erx_passphrase_hash.erl'

  Fault = Data.define(:name, :path, :from, :to, :caught_by)

  FAULTS = [
    Fault.new(name: 'a stranger answered as root', path: CHECK,
              from: 'answer(?ROOT, true) -> match;', to: 'answer(_, true) -> match;',
              caught_by: 'a_stranger_with_root_s_passphrase_is_no_match_test'),
    Fault.new(name: 'a stranger answered without a derivation', path: CHECK,
              from: "derived({ok, Bytes}, Name, Passphrase) ->\n",
              to: "derived({ok, _}, Name, _) when Name =/= ?ROOT -> no_match;\nderived({ok, Bytes}, Name, Passphrase) ->\n",
              caught_by: 'no_record_is_unavailable_for_every_name_test'),
    Fault.new(name: 'the counts not applied', path: CHECK,
              from: 'case erx_passphrase_limits:admit(Name, Terminal, Now(), Counts) of',
              to: 'case ok of', caught_by: 'five_failures_limit_the_name_test'),
    Fault.new(name: 'a release build that reads the file', path: CHECK,
              from: "handle_info({?MODULE, check, Alias, _Name, _Passphrase, _Terminal}, \#{development := false} = State) ->\n    Alias ! {Alias, unavailable},\n    {noreply, State};\n",
              to: '', caught_by: 'a_release_build_reads_nothing_test'),
    Fault.new(name: 'two derivations at once', path: CHECK,
              from: 'next(#{busy := none, queue := Queue', to: 'next(#{queue := Queue',
              caught_by: 'checks_wait_for_one_derivation_at_a_time_test'),
    Fault.new(name: 'the raw queue shown in the status', path: CHECK,
              from: '#{queued => queue:len(Queue),', to: '#{raw => Queue, queued => queue:len(Queue),',
              caught_by: 'no_status_shows_a_request_test'),
    Fault.new(name: 'no deadline on a worker', path: CHECK,
              from: '    exit(Worker, kill),', to: '    _ = Worker,',
              caught_by: 'a_worker_past_its_deadline_is_unavailable_and_not_counted_test'),
    Fault.new(name: 'eagain taken as an answer', path: CHECK,
              from: '{error, eagain} -> timer:sleep(?EAGAIN_MS), settled(Read);', to: '',
              caught_by: 'the_first_check_waits_out_the_tree_s_eagain_test'),
    Fault.new(name: 'a malformed line accepted: spare bits set', path: LINE,
              from: 'LastWord bsr 16 =:= 0 orelse fail(),', to: 'true,',
              caught_by: 'a_hash_with_spare_bits_set_is_refused_test'),
    Fault.new(name: 'a malformed line accepted: bytes after the line', path: LINE,
              from: 'line_end(_) -> fail().', to: 'line_end(_) -> ok.',
              caught_by: 'malformed_lines_are_refused_test'),
    Fault.new(name: 'a malformed record accepted: any rounds', path: HASH,
              from: 'case Rounds >= ?ROUNDS_MIN andalso Rounds =< ?ROUNDS_MAX', to: 'case true',
              caught_by: 'a_record_from_another_domain_is_checked_test'),
    Fault.new(name: 'the comparison ends at the first byte', path: HASH,
              from: 'lists:zip(binary_to_list(A), binary_to_list(B))', to: '[{binary:first(A), binary:first(B)}]',
              caught_by: 'a_hash_differing_in_its_last_byte_does_not_match_test')
  ].freeze

  # crypt-sha256.c's tests2[], as test/erlang/erx_passphrase_tests.erl lists them.
  VECTORS = [
    ['saltstring', 5000, 'Hello world!', '$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5'],
    ['saltstringsaltst', 10_000, 'Hello world!',
     '$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA'],
    ['short', 77_777, 'we have a short salt string but not a short password',
     '$5$rounds=77777$short$JiO1O3ZpDAxGJeaDIuqCoEFysAe1mZNJRs3pw0KQRd/']
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
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_passphrase_tests: ).)*?\*(?:failed|timed out)\*/m,
                   output, fault.name)
    end
  end

  def test_the_tool_writes_freebsd_s_lines
    VECTORS.each do |salt, rounds, key, line|
      assert_equal line, Erx::PassphraseHash.line(key, salt: salt, rounds: rounds)
    end
  end

  def test_the_tool_reads_a_line_of_standard_input_and_prints_one_line
    output = StringIO.new
    Erx::PassphraseHash.command([], input: StringIO.new("Hello world!\n"), output: output)
    assert_match(%r{\A\$5\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{43}\n\z}, output.string)
    refute_includes output.string, 'Hello'
  end

  def test_the_tool_refuses_an_empty_passphrase
    assert_raises(Erx::PassphraseHash::Refused) do
      Erx::PassphraseHash.command([], input: StringIO.new("\n"), output: StringIO.new)
    end
  end

  private

  def eunit(replaced)
    Dir.mktmpdir('erx-passphrase-test') do |work|
      sources = HOST_BYTES.to_h { |path, stand_in| [path, File.read(File.join(ROOT, stand_in))] }
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: sources.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_passphrase_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
