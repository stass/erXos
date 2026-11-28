# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'etc'
require 'fileutils'
require 'find'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/fat_volume'
require_relative '../../tools/lib/erx/fsimg'
require_relative '../../tools/lib/erx/line_escape'
require_relative '../../tools/lib/erx/oracle'

# A seeded, fio-shaped load of the FAT server's write path: test/erlang/erx_fat_load.erl
# drives a volume process (erx_media_volume) over an empty FAT32 volume fsimg makes,
# through the calls the media tree sends for a session's file operations, and checks
# every byte against its model as it reads, after each job and after a remount. The
# image it leaves must then pass fsimg's verify, macOS's fsck_msdos -n where the host
# has it, and fsimg's extract must hold exactly the model's files and directories.
#
# The default run is short, for make check. ERX_FAT_LOAD_SOAK runs a soak instead, a
# comma-separated list of MIB:CLUSTER:OPS volumes (`soak` for SOAK below), and prints
# each job's throughput; ERX_FAT_LOAD_SEED fixes the seed, which is otherwise the
# default's, or random for a soak. A run that fails keeps its image and names it, with
# the seed and the count of the volume's calls at the failure.
#
# The numbers are host numbers of the server's logic, the volume process and the FAT
# modules on stock's emulator over an image file in the page cache, not a device's.
class ErxFatLoadTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  TESTS = %w[test/erlang/erx_fat_load.erl].freeze
  ALLOC = 'erlang/apps/erx_fat/src/erx_fat_alloc.erl'
  PLAN = 'erlang/apps/erx_fat/src/erx_fat_plan.erl'

  Volume = Data.define(:mib, :cluster, :ops) do
    def self.parse(text)
      mib, cluster, ops = text.split(':').map { |field| Integer(field, 10) }
      new(mib: mib, cluster: cluster || 4096, ops: ops || 5000)
    end

    def to_s = "#{mib} MiB, #{cluster}-byte clusters, #{ops} calls a random job"
  end

  # FAT32's least volume of 512-byte clusters, with room for the jobs.
  SHORT = Volume.new(mib: 40, cluster: 512, ops: 300)
  SOAK = 'soak'
  SOAK_VOLUMES = '300:4096:5000,1024:4096:20000,4096:32768:20000'
  DEFAULT_SEED = 1

  Fault = Data.define(:name, :path, :from, :to, :caught_by)

  # Each fault replaces one passage; the short run must fail in the named job, or, for
  # IMAGE, pass the driver and leave an image that fails fsimg's verify, fsck_msdos or
  # the extract.
  IMAGE = 'image'
  FAULTS = [
    Fault.new(name: 'a cluster the batch allocated taken as free', path: ALLOC,
              from: 'not is_map_key(Cluster, Batch) andalso Value =:= ?FREE', to: 'Value =:= ?FREE',
              caught_by: 'files'),
    Fault.new(name: 'the next-fit search not wrapping to the first cluster', path: ALLOC,
              from: 'Ranges = [{Next, Clusters + 1}, {2, Next - 1}],', to: 'Ranges = [{Next, Clusters + 1}],',
              caught_by: 'files'),
    Fault.new(name: 'a held sector counted at its 512 bytes alone', path: ALLOC,
              from: '-define(HELD_SECTOR_BYTES, ((2 * ?SECTOR + 4 * ?HELD_SECTOR_WORDS * 8 + 1023) div 1024 * 1024)).',
              to: '-define(HELD_SECTOR_BYTES, ?SECTOR).',
              caught_by: 'seq'),
    Fault.new(name: 'a FAT sector written to the first FAT alone', path: PLAN,
              from: 'Stride, Count}, Copy) when Copy < Count ->', to: 'Stride, Count}, Copy) when Copy < 1 ->',
              caught_by: IMAGE)
  ].freeze

  def test_a_seeded_load_reads_back_and_leaves_a_volume_that_checks
    volumes.each do |volume|
      seed = Integer(ENV.fetch('ERX_FAT_LOAD_SEED') { soak? ? rand(1 << 31).to_s : DEFAULT_SEED.to_s }, 10)
      outcome = load(volume, seed: seed, replaced: {})
      assert outcome.passed?, outcome.failure
      puts outcome.report if soak?
      outcome.discard
    end
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      skip 'a soak runs the load alone' if soak?
      original = File.read(File.join(ROOT, fault.path))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      outcome = load(SHORT, seed: DEFAULT_SEED, replaced: { fault.path => original.sub(fault.from) { fault.to } })
      refute outcome.passed?, "#{fault.name}: the load passed"
      if fault.caught_by == IMAGE
        refute_match(/FAILED/, outcome.output, fault.name)
        assert_match(/\A(?:fsimg verify|fsck_msdos -n|fsimg extract)/, outcome.failure, fault.name)
      else
        assert_match(/FAILED seed=#{DEFAULT_SEED} op=\d+ job=#{fault.caught_by}: /, outcome.output, fault.name)
      end
      outcome.discard
    end
  end

  # One run: its image's directory, the driver's output and the first failure.
  Outcome = Data.define(:directory, :volume, :seed, :output, :failure) do
    def passed? = failure.nil?

    def discard = FileUtils.rm_rf(directory)

    def report
      rows = output.lines.grep(/\ARESULT /).map { |line| line.split.drop(1) }
      header = "FAT load, #{volume}, seed #{seed}: host #{Etc.uname[:sysname]} #{Etc.uname[:machine]}, " \
               "#{output.lines.first&.strip}; host numbers of the server's logic over an image file, not a device's"
      [header, *rows.map { |job, kind, calls, bytes, us| row(job, kind, Integer(calls), Integer(bytes), Integer(us)) }]
        .join("\n")
    end

    private

    def row(job, kind, calls, bytes, microseconds)
      seconds = [microseconds, 1].max / 1e6
      rate = bytes.positive? ? format('%9.1f MB/s', bytes / seconds / 1e6) : ' ' * 14
      format('  %-14s %-8s %8d calls %12d bytes %9.3f s %s %10.0f calls/s', job, kind, calls, bytes, seconds, rate,
             calls / seconds)
    end
  end

  private

  def soak? = ENV.key?('ERX_FAT_LOAD_SOAK')

  def volumes
    return [SHORT] unless soak?

    text = ENV.fetch('ERX_FAT_LOAD_SOAK')
    (text == SOAK ? SOAK_VOLUMES : text).split(',').map { |field| Volume.parse(field) }
  end

  # The load over a fresh volume, with the replaced module texts, and the checks of
  # the image it leaves.
  def load(volume, seed:, replaced:)
    directory = Dir.mktmpdir('erx-fat-load')
    image = File.join(directory, 'load.img')
    make_volume(directory, image, volume)
    output, status = drive(directory, image, volume, seed, replaced)
    failure = status.success? ? image_failure(directory, image) : output.lines.grep(/FAILED/).first || output
    failure &&= Erx::LineEscape.escape(failure)
    Outcome.new(directory: directory, volume: volume, seed: seed, output: output,
                failure: failure && "#{failure}\nseed #{seed}; image kept at #{image}")
  end

  def make_volume(directory, image, volume)
    empty = File.join(directory, 'empty')
    FileUtils.mkdir_p(empty)
    run!(fsimg, 'cW', '-f', image, '-F', 'fat32', '-s', (volume.mib << 20).to_s, '-L', 'LOAD',
         '-o', "cluster=#{volume.cluster}", *Erx::FatVolume::FSIMG_EPOCH, '-C', empty, '.')
  end

  def drive(directory, image, volume, seed, replaced)
    work = File.join(directory, 'beam')
    FileUtils.mkdir_p(work)
    ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
    deadline = soak? ? 7200 : 300
    Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', deadline.to_s, ENV.fetch('ERX_ERL'),
                    '-noshell', '-pa', work, '-run', 'erx_fat_load', 'main', image, File.join(directory, 'manifest'),
                    seed.to_s, volume.ops.to_s, chdir: directory, stdin_data: '')
  end

  # The first check the image fails: fsimg's verify, fsck_msdos's, or the extract
  # against the manifest; nil when it passes them all.
  def image_failure(directory, image)
    verify, status = Open3.capture2e(fsimg, 'W', '-f', image, stdin_data: '')
    return "fsimg verify: #{verify}" unless status.success?

    fsck, status = fsck_msdos(image)
    return "fsck_msdos -n: #{fsck}" unless status.nil? || status.success?

    extract_failure(directory, image)
  end

  # macOS's fsck_msdos or FreeBSD's fsck_msdosfs; neither on the host skips the check.
  def fsck_msdos(image)
    tool = %w[/sbin/fsck_msdos /sbin/fsck_msdosfs].find { |path| File.executable?(path) }
    return [nil, nil] unless tool

    Open3.capture2e(tool, '-n', image, stdin_data: '')
  end

  def extract_failure(directory, image)
    out = File.join(directory, 'extract')
    FileUtils.mkdir_p(out)
    run!(fsimg, 'x', '-f', image, '-C', out)
    top = Dir.children(out)
    return "fsimg extract: #{top.size} top entries" unless top.size == 1

    got = extracted(File.join(out, top.first))
    expected = File.readlines(File.join(directory, 'manifest'), chomp: true).sort
    return nil if got == expected

    "fsimg extract differs: missing #{(expected - got).first(5)}, unexpected #{(got - expected).first(5)}"
  end

  # The extract's lines, as the manifest writes them.
  def extracted(tree)
    Find.find(tree).filter_map do |path|
      relative = path.delete_prefix("#{tree}/")
      next if path == tree

      if File.directory?(path)
        "d #{relative}"
      else
        "f #{File.size(path)} #{Digest::MD5.file(path).hexdigest} #{relative}"
      end
    end.sort
  end

  def fsimg = Erx::Fsimg.locate(root: ROOT)

  def run!(*command)
    output, status = Open3.capture2e(*command, stdin_data: '')
    raise "#{command.first(2).join(' ')} failed: #{output}" unless status.success?

    output
  end
end
