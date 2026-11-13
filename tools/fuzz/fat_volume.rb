#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/fsimg'
require_relative '../lib/erx/pi_medium'

# The packer's FAT reader (Erx::FatVolume) over mutated volumes: the Pi card's record
# volume and slot A's volume as the pinned fsimg writes them with the card's own
# arguments (Erx::PiMedium), with bytes changed in the boot sector, the first FAT, the
# root directory and the placed file, and cut short. Each input either raises
# Erx::Error and nothing else, or passes the placement check, and then the file read
# along its cluster chain, as a reader that knows nothing of placement reads it, is the
# placed file. Whether the check refuses each wrong placement is
# test/host/pi_medium_test.rb's.
module Erx
  module FatVolumeFuzz
    ROOT = File.expand_path('../..', __dir__)
    MEDIUM = PiMedium
    KERNEL = Random.new(1).bytes((7 * 1024) + 3)

    # A seed volume, the check's arguments for it, and the regions a mutation aims at.
    Seed = Data.define(:bytes, :kind, :short, :offset, :contents, :regions)
    # A mutated volume: the seed's bytes, unchanged and shared, with patches (offset to
    # byte) over them, size bytes long; what FatVolume::Volume reads of a file.
    Patched = Data.define(:base, :patches, :size) do
      def pread(length, offset)
        bytes = base.byteslice(offset, [[length, size - offset].min, 0].max) || ''.b
        patches.each { |at, byte| bytes.setbyte(at - offset, byte) if at >= offset && at < offset + bytes.bytesize }
        bytes
      end
    end

    module_function

    def seeds
      fsimg = Fsimg.locate(root: ROOT)
      Dir.mktmpdir('erx-fat-fuzz-') do |work|
        [seed(fsimg, work, 'record', MEDIUM::RECORD_VOLUME, MEDIUM::RECORD_FILE, BootRecord::SLOTS.fetch(:a).text,
              kind: :fat16, offset: MEDIUM::RECORD_PLACE),
         seed(fsimg, work, 'slot', MEDIUM::SLOT_VOLUME, MEDIUM::BOOT_FILE, KERNEL, kind: :fat32, offset: MEDIUM::BOOT_PLACE)]
      end
    end

    def seed(fsimg, work, name, arguments, file, contents, kind:, offset:)
      files = File.join(work, name)
      Dir.mkdir(files)
      File.binwrite(File.join(files, file), contents)
      File.write(File.join(files, 'config.txt'), "x\n")
      image = File.join(work, "#{name}.fat")
      output, status = Open3.capture2e(fsimg, 'cW', '-f', image, *arguments, '-C', files, '.', stdin_data: '')
      raise "fsimg cannot write the #{name} seed: #{output}" unless status.success?

      bytes = File.binread(image).freeze
      layout = FatVolume::Volume.new(FatVolume::Bytes.new(bytes), size: bytes.bytesize, label: name).layout
      root = layout.kind.name == :fat16 ? layout.root_offset : layout.cluster_offset(layout.root_cluster)
      regions = [[0, 512], [layout.fat_offset, 4096], [root, 1024], [layout.data_offset, 4096], [offset, 2048]]
      Seed.new(bytes: bytes, kind: kind, short: FatShortNames.short_form(file).name, offset: offset, contents: contents.b,
               regions: regions)
    end

    def mutate(seed, random)
      patches = {}
      random.rand(1..6).times do
        start, length = seed.regions.sample(random: random)
        patches[start + random.rand(length)] = random.rand(4).zero? ? [0, 0xff, 0xf8, 0x02].sample(random: random) : random.rand(256)
      end
      size = random.rand(8).zero? ? random.rand(seed.bytes.bytesize) : seed.bytes.bytesize
      Patched.new(base: seed.bytes, patches: patches.freeze, size: size)
    end

    def exercise(seed, source)
      volume = FatVolume::Volume.new(source, size: source.size, label: 'fuzz')
      volume.root_entries
      entry = FatVolume.check_placed(volume, kind: seed.kind, short: seed.short, offset: seed.offset, contents: seed.contents)
      raise 'an accepted placement does not read back through its chain' unless through_chain(volume, entry) == seed.contents
    rescue Erx::Error
      nil
    end

    # The file of an accepted entry as a FAT reader that never heard of placement reads it:
    # cluster by cluster along its chain, apart from check_placed's walk.
    def through_chain(volume, entry)
      layout = volume.layout
      cluster = entry.first_cluster
      bytes = ''.b
      while bytes.bytesize < entry.size
        bytes << volume.read(layout.cluster_offset(cluster), layout.cluster_bytes)
        cluster = volume.fat_entry(cluster)
      end
      bytes.byteslice(0, entry.size)
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      # Each seed as fsimg wrote it passes, so the mutations start from accepted volumes.
      initial.each do |each|
        volume = FatVolume::Volume.new(FatVolume::Bytes.new(each.bytes), size: each.bytes.bytesize, label: "the #{each.kind} seed")
        FatVolume.check_placed(volume, kind: each.kind, short: each.short, offset: each.offset, contents: each.contents)
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        chosen = initial.sample(random: random)
        exercise(chosen, mutate(chosen, random))
        count += 1
      end
      count
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 3, seed: 1 }
  OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!(ARGV)
  raise OptionParser::InvalidArgument, 'budget of 1..60 seconds' unless options[:seconds].between?(1, 60)

  puts "FAT volume reader: #{Erx::FatVolumeFuzz.run(**options)} inputs"
end
