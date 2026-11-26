# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'
require_relative '../../tools/lib/erx/fsimg'

# FAT's names and the FAT server's directory changes (docs/design-storage.md,
# "Removable media: FAT"): test/erlang/erx_fat_dir_tests.erl runs on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies) over the FAT16 and FAT32 volumes
# fsimg writes of FatVolumes' tree, whose results fsimg's verify and extract check,
# against erx_fat_dir, erx_fat_name and erx_fat as they are and against each seeded
# fault below, where the named case must fail.
class ErxFatDirTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DIR = 'erlang/apps/erx_fat/src/erx_fat_dir.erl'
  NAME = 'erlang/apps/erx_fat/src/erx_fat_name.erl'
  FAT = 'erlang/apps/erx_fat/src/erx_fat.erl'
  ALLOC = 'erlang/apps/erx_fat/src/erx_fat_alloc.erl'
  APPLICATIONS = %w[erx erx_fat].freeze
  TESTS = %w[test/erlang/erx_fat_dir_tests.erl test/erlang/erx_fat_alloc_tests.erl].freeze

  Fault = Data.define(:name, :file, :from, :to, :caught_by)

  # Each fault replaces one passage of a module; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: "a name's entries written in linking", file: DIR,
              from: 'set_entry(Acc, publication, slot(Sectors, Index), Bytes)',
              to: 'set_entry(Acc, linking, slot(Sectors, Index), Bytes)', caught_by: 'volumes_test_'),
    Fault.new(name: "a moved directory's `..` written in preparation", file: DIR,
              from: 'set_entry(B, linking, dotdot_slot(B, Cluster),',
              to: 'set_entry(B, preparation, dotdot_slot(B, Cluster),', caught_by: 'volumes_test_'),
    Fault.new(name: 'a duplicate name not refused', file: DIR,
              from: 'erx_fat_name:matched(Scan#scan.match) =:= none orelse fail(eexist),',
              to: 'true,', caught_by: 'volumes_test_'),
    Fault.new(name: "the case table's fold dropped past Latin-1", file: NAME,
              from: '<<(erx_fat_case:upper(Unit)):16>>',
              to: '<<(case Unit < 16#100 of true -> erx_fat_case:upper(Unit); false -> Unit end):16>>',
              caught_by: 'names_compare_by_bmp_simple_uppercase_test'),
    Fault.new(name: 'the end marker after a name not written', file: DIR,
              from: 'cleared(B, Sectors, max(Start, End), min(Start + Count, Total - 1))',
              to: 'cleared(B, Sectors, max(Start, End), min(Start + Count - 1, Total - 1))',
              caught_by: 'a_name_past_the_end_marker_is_followed_by_one_test'),
    Fault.new(name: 'a short-only name placed after stray long-name entries', file: DIR,
              from: '{short_only, {_, _, false} = Alone} -> {[], Alone};',
              to: '{short_only, {_, _, _} = Alone} -> {[], Alone};',
              caught_by: 'stray_long_entries_never_name_a_short_only_name_test'),
    Fault.new(name: 'the whole directory collected before a change reads it', file: DIR,
              from: 'folded(B, Dir, Fun, Acc) -> ok(erx_fat:fold(Dir, view(B), Fun, Acc)).',
              to: "folded(B, Dir, Fun, Acc) ->\n" \
                  "    {Events, Read} = ok(erx_fat:fold(Dir, view(B), fun(I, E, Got) -> [{I, E} | Got] end, [])),\n" \
                  "    {lists:foldl(fun({I, E}, A) -> Fun(I, E, A) end, Acc, lists:reverse(Events)), Read}.",
              caught_by: 'a_directory_near_the_entries_bound_changes_within_the_memory_bound_test_'),
    Fault.new(name: 'a file grown by a truncate not zeroed', file: DIR,
              from: 'contents(B, File, Old, <<0:((Size - Old) * 8)>>, Size, Publish);',
              to: 'Publish(B, File, erx_fat:first(File), Size);', caught_by: 'contents_test_'),
    Fault.new(name: "a new run's link into another FAT sector written in preparation", file: ALLOC,
              from: "    not end_of_chain(Alloc, Value)\n        andalso entry_sector",
              to: "    Value =:= Cluster andalso not end_of_chain(Alloc, Value)\n        andalso entry_sector",
              caught_by: 'a_run_across_fat_sectors_survives_every_cut_test_')
  ].freeze

  def self.images
    @images ||= Dir.mktmpdir('erx-fat-dir-images').tap do |directory|
      FatVolumes.write(directory, root: ROOT)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

  def test_the_cases_pass
    output, status = eunit({}, 'erx_fat_dir_tests')
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  # The ownership check's directories waiting to be walked are bounded: seeded to 2,
  # a volume that pushes three is too large.
  def test_the_check_bounds_its_pending_directories
    from = '-define(CHECK_PENDING_MAX, (?ERX_MEDIA_VOLUME_BYTES div 8 div 16)).'
    original = File.read(File.join(ROOT, FAT))
    assert_equal 1, original.scan(from).size
    output, status = eunit({ FAT => original.sub(from, '-define(CHECK_PENDING_MAX, 2).') },
                           '{erx_fat_dir_tests, check_bound_case}')
    assert status.success?, output
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.file))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.file => original.sub(fault.from) { fault.to } }, 'erx_fat_dir_tests')
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}.*?\*failed\*/m, output, fault.name)
    end
  end

  private

  # Compiles erx_fat with replaced (path => text) and the suites, and runs tests.
  def eunit(replaced, tests)
    Dir.mktmpdir('erx-fat-dir-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      environment = { 'ERX_FAT_IMAGES' => self.class.images, 'ERX_FSIMG' => Erx::Fsimg.locate(root: ROOT) }
      Open3.capture2e(environment, 'gtimeout', '-k', '10', '900', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "halt(case eunit:test(#{tests}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
