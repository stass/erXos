# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/data_volume'
require_relative '../../tools/lib/erx/runner'

# F2FS's format, erx_f2fs_format (docs/design-f2fs.md, "Formatting a volume" and "Unit and
# property tests"): its EUnit cases on stock's emulator (ERX_ERL and ERX_ERLC), then the
# same cases against a format with one seeded fault each, which must fail the case named
# for it, the property case over the geometries alone.
class ErxF2fsFormatTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FORMAT = 'erlang/apps/erx_f2fs/src/erx_f2fs_format.erl'
  TESTS = %w[test/erlang/erx_f2fs_format_tests.erl].freeze
  CASE = 'each_plan_writes_a_valid_volume_inside_its_partition_test_'
  VALID = /failed/

  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "segment 0 on a section boundary of the partition, not of the medium",
             anchor: '    Segment0 = ceil_to(First + ?SUPER_BLOCKS, Section) - First,',
             replacement: '    Segment0 = ceil_to(?SUPER_BLOCKS, Section),',
             failure: VALID),
    Seed.new(fault: 'two logs sharing a section',
             anchor: 'log_segment(#{section := S}, Type) -> Type * S.',
             replacement: 'log_segment(#{section := _}, Type) -> Type.',
             failure: VALID),
    Seed.new(fault: "the SIT's count missing the root's dentry block",
             anchor: "                ?WARM_DATA -> 1;\n",
             replacement: '',
             failure: VALID),
    Seed.new(fault: "the NAT's first copy written as the area's first half",
             anchor: '        [{NatAddress + ?BLOCKS_PER_SEG * 2 * (Index div ?BLOCKS_PER_SEG) + Index rem ?BLOCKS_PER_SEG,',
             replacement: '        [{NatAddress + Index,',
             failure: VALID)
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    text = File.read(File.join(ROOT, FORMAT))
    SEEDS.each do |seed|
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ FORMAT => text.sub(seed.anchor) { seed.replacement } }, only: CASE)
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  # DataVolume's hook runs the plan on the host and places it: a medium made from its
  # pieces holds every block as the plan's last phase leaves it, the superblock's magic
  # 1024 bytes into the data partition, and nothing outside the partition.
  def test_data_volume_places_the_plan_in_the_data_partition
    Dir.mktmpdir('erx-f2fs-volume-test') do |directory|
      start = Erx::MediumImage.constant('data_start')
      volume = Erx::DataVolume.f2fs(root: ROOT, runner: runner(directory), directory: directory, start: start,
                                    sectors: Erx::MediumImage::PACKED_DATA_SECTORS, version: 0x2468ace1,
                                    uuid: "\x5a".b * 16, time: 1_700_000_000)
      assert_equal 3, volume.phases.size
      medium = Erx::MediumImage.create(directory: directory, name: 'medium.img', pieces: volume.pieces,
                                       data_sectors: Erx::MediumImage::PACKED_DATA_SECTORS)
      File.open(medium, 'rb') do |image|
        final = volume.phases.flatten(1).to_h
        final.each { |address, block| assert_equal block, image.pread(4096, (start * 512) + (address * 4096)), "block #{address}" }
        assert_equal [0xf2f52010], image.pread(4, (start * 512) + 1024).unpack('V')
      end
    end
  end

  def test_data_volume_reports_what_the_format_refuses
    Dir.mktmpdir('erx-f2fs-volume-test') do |directory|
      error = assert_raises(Erx::Error) do
        Erx::DataVolume.f2fs(root: ROOT, runner: runner(directory), directory: directory, start: 8, sectors: 4096,
                             version: 1, uuid: ("\x00".b * 16), time: 0)
      end
      assert_match(/refuses: \{geometry,too_small\}/, error.message)
    end
  end

  private

  def runner(directory) = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))

  # Runs the EUnit cases against erx and erx_f2fs with the given sources replaced; the
  # output and status.
  def eunit(replaced, only: nil)
    Dir.mktmpdir('erx-f2fs-format-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      ErlangBuild.eunit_eval(ErlangBuild.eunit_spec(TESTS, only)),
                      chdir: work, stdin_data: '')
    end
  end
end
