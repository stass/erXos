# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_record_volume'

# The login_keys tree's holder and its reader (docs/design-ssh.md, "When it is there"
# and "Verification"): test/erlang/erx_storage_login_keys_tests.erl runs on stock's
# emulator over the volumes FatRecordVolume writes, against erx_storage_login_keys as it
# is and against each seeded fault below, where the named case must fail.
class ErxStorageLoginKeysTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_storage/src/erx_storage_login_keys.erl'
  APPLICATIONS = %w[erx erx_files erx_blk erx_storage].freeze
  TESTS = %w[test/erlang/erx_storage_login_keys_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_storage_login_keys; the case named in
  # caught_by must fail.
  FAULTS = [
    Fault.new(name: "the result published only by the reader's message",
              from: "{'DOWN', Monitor, process, _Reader, _Reason} ->\n            decided(publish(read_failed, Log));",
              to: "{'DOWN', Monitor, process, _Reader, _Reason} ->\n            loading(Monitor, Log);",
              caught_by: 'a_killed_reader_is_eio_not_an_empty_root_test'),
    Fault.new(name: 'the empty file published for a reader that did not read',
              from: "keys(read_failed, Log) ->\n    _ = Log([\"authorized_keys: \", reason(read_failed)]),\n    {error, eio}.",
              to: "keys(read_failed, Log) ->\n    _ = Log([\"authorized_keys: \", reason(read_failed)]),\n    {ok, <<>>}.",
              caught_by: 'a_killed_reader_is_eio_not_an_empty_root_test'),
    Fault.new(name: 'a result under any tag taken',
              from: '{Monitor, {result, Result}} ->', to: '{_, {result, Result}} ->',
              caught_by: 'a_result_under_another_tag_is_dropped_test'),
    Fault.new(name: 'a late result taken once decided',
              from: "decided(Answers) ->\n    receive\n",
              to: "decided(Answers) ->\n    receive\n        {_, {result, {{keys, Late, _}, _}}} -> decided(Answers\#{root := {ok, iolist_to_binary(Late)}});\n",
              caught_by: 'a_result_after_the_reader_s_end_changes_nothing_test'),
    Fault.new(name: 'the medium read at the mount',
              from: "    proc_lib:init_ack(Parent, {ok, self()}),\n    idle(Read, Log).",
              to: "    proc_lib:init_ack(Parent, {ok, self()}),\n    loading(start_reader(Read), Log).",
              caught_by: 'no_sector_is_read_until_root_is_asked_test'),
    Fault.new(name: 'a read past the request',
              from: 'min(Count, byte_size(Bytes) - Offset)', to: 'byte_size(Bytes) - Offset',
              caught_by: 'reads_stay_within_the_file_test')
  ].freeze

  def self.volumes
    @volumes ||= Dir.mktmpdir('erx-login-keys-volumes').tap do |directory|
      FatRecordVolume.write_cases(directory)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name.
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_storage_login_keys_tests: ).)*?\*(?:failed|timed out)\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the holder as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-login-keys-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e({ 'ERX_FAT_VOLUMES' => self.class.volumes },
                      'gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_storage_login_keys_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
