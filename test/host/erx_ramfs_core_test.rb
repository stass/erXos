# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_ramfs_core_tests.erl, the EUnit cases of the pure tree behind
# /tmp, against erx_ramfs_core compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies). Then each seeded fault of docs/design-tmp.md's
# "Core" item, applied to a copy of the module, must fail the case named for it, which
# shows that case runs the code the fault breaks.
class ErxRamfsCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'otp/lib/kernel/src/erx_ramfs_core.erl')
  TESTS_SOURCE = File.join(ROOT, 'test/erlang/erx_ramfs_core_tests.erl')

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a rename that does not lower the replaced node links',
             anchor: "    drop_name(Replaced, NewDir, Now,\n              update(NewDir, " \
                     "fun(P) -> remove_entry(P, NewName) end, Tree)).",
             replacement: '    update(NewDir, fun(P) -> remove_entry(P, NewName) end, Tree).',
             catching_case: 'rename_over_a_file_frees_the_replaced_test'),
    Seed.new(fault: 'an ancestor check that compares only the immediate parent',
             anchor: 'ancestor(Ancestor, Parent, Fuel - 1, Tree);',
             replacement: 'Ancestor =:= Parent;',
             catching_case: 'rename_into_grandchild_is_einval_test'),
    Seed.new(fault: 'a write that charges every touched chunk',
             anchor: 'New = length([I || I <- Touched, not is_map_key(I, Chunks)]),',
             replacement: 'New = length(Touched),',
             catching_case: 'overwrite_costs_nothing_test'),
    Seed.new(fault: 'a name stored without copying',
             anchor: 'Stored = binary:copy(Name),',
             replacement: 'Stored = Name,',
             catching_case: 'stored_binaries_are_copies_test'),
    Seed.new(fault: 'a write that keeps the file version',
             anchor: "mtime = Now, ctime = Now, version = Stamp},\n        {done, {ok, byte_size(Bytes), At},",
             replacement: "mtime = Now, ctime = Now, version = N#node.version},\n        " \
                          '{done, {ok, byte_size(Bytes), At},',
             catching_case: 'write_sets_mtime_ctime_and_version_test'),
    Seed.new(fault: 'a rename that leaves the new directory times and version',
             anchor: 'fun(T) -> update(NewDir, fun(P) -> changed(P, Stamp, Now) end, T) end]',
             replacement: 'fun(T) -> T end]',
             catching_case: 'rename_changes_both_directories_and_the_nodes_test')
  ].freeze

  def test_core_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE), warnings_as_errors: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert source.include?(seed.anchor), "no anchor for #{seed.fault} in #{MODULE_SOURCE}"
      output, status = eunit(source.sub(seed.anchor, seed.replacement), warnings_as_errors: false)
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_match(/#{seed.catching_case}\.\.\.(\[[^\]]*\] )?\*failed\*/, output,
                   "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  def eunit(module_text, warnings_as_errors:)
    Dir.mktmpdir('erx-ramfs-core-test') do |work|
      module_path = File.join(work, 'erx_ramfs_core.erl')
      File.binwrite(module_path, module_text)
      flags = warnings_as_errors ? ['-Werror'] : []
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, '-o', work, module_path, TESTS_SOURCE,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_ramfs_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
