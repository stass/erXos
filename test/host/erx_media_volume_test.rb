# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'

# Runs test/erlang/erx_media_volume_tests.erl, the EUnit cases of a medium's supervisor,
# reader and volume processes, against erx_media compiled from source on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the FAT16 and FAT32
# volumes fsimg makes (FatVolumes), and seeds the faults docs/design-drives.md's host
# tests name for them.
class ErxMediaVolumeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  TESTS = %w[test/erlang/erx_media_volume_tests.erl].freeze
  MEDIUM = 'erlang/apps/erx_media/src/erx_media_medium.erl'
  VOLUME = 'erlang/apps/erx_media/src/erx_media_volume.erl'
  DRIVE = 'erlang/apps/erx_media/src/erx_media_drive.erl'

  Fault = Data.define(:name, :path, :from, :to, :caught_by)

  # Each fault replaces one passage of a module; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'max_heap_size given media_volume_bytes as words unconverted', path: MEDIUM,
              from: '?ERX_MEDIA_VOLUME_BYTES div erlang:system_info(wordsize)', to: '?ERX_MEDIA_VOLUME_BYTES',
              caught_by: 'each_volume_runs_under_its_memory_bound_and_ends_alone_test'),
    Fault.new(name: 'a volume started as a permanent child', path: MEDIUM,
              from: "start => {erx_media_volume, start_link, [Proxy, Volume]},\n             restart => temporary}",
              to: "start => {erx_media_volume, start_link, [Proxy, Volume]},\n             restart => permanent}",
              caught_by: 'each_volume_runs_under_its_memory_bound_and_ends_alone_test'),
    Fault.new(name: "a volume's sectors read from the medium's start", path: VOLUME,
              from: '{ok, Lba} -> erx_media_medium:window(Proxy, {read, Lba, 1});',
              to: '{ok, _Lba} -> erx_media_medium:window(Proxy, {read, Sector, 1});',
              caught_by: 'each_volume_reads_at_its_own_place_test'),
    Fault.new(name: 'a failed flush taken as a medium that cannot flush', path: VOLUME,
              from: 'flushed({error, enotsup}, _Clean) -> {ro, flush};',
              to: 'flushed({error, _}, _Clean) -> {ro, flush};',
              caught_by: 'a_flush_decides_between_rw_ro_and_none_test'),
    Fault.new(name: 'the also condition removed', path: VOLUME,
              from: '{true, [Name | _]} -> {ro, {also, Name}};', to: '{true, [_Name | _]} -> flushed(Flush(), Clean);',
              caught_by: 'the_rule_names_its_first_failing_condition_test'),
    Fault.new(name: "the proxy's end leaving the medium's supervisor running", path: DRIVE,
              from: "    stop(Sup),\n    {noreply, State\#{medium := none}};", to: "    _ = Sup,\n    {noreply, State\#{medium := none}};",
              caught_by: 'the_drive_mounts_its_medium_at_the_ask_and_ends_it_with_its_proxy_test'),
    Fault.new(name: "an idle medium's supervisor left running", path: DRIVE,
              from: '_Idle -> stop(Sup), none', to: '_Idle -> none',
              caught_by: 'a_refused_table_leaves_the_medium_idle_with_no_supervisor_test')
  ].freeze

  def self.images
    @images ||= Dir.mktmpdir('erx-media-volume-images').tap do |directory|
      FatVolumes.write(directory, root: ROOT)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

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
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_media_volume_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the applications with the replaced module texts, and the suite, and runs it.
  def eunit(replaced)
    Dir.mktmpdir('erx-media-volume-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images },
                      'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_media_volume_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
