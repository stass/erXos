# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=900

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_f2fs_codec, F2FS's codec (test/erlang/erx_f2fs_fuzz.erl,
# docs/design-f2fs.md, "Reading the medium"): every reader over mutations of the
# codec tests' fixtures and of the corpus images' superblocks and checkpoint packs,
# the checksums mostly fixed up, fail every malformed block with an error naming the
# rule, never a crash. The corpus images are decoded from the files the fetch step put
# in build/third_party and checked against their deps.lock pins, so the target fails,
# naming the image, until every corpus source is fetched. Compiled
# from source with erx_abi_packed, which the ABI generator writes into build/gen, and
# run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the codec as it
# is, then each seeded fault the design names for these readers applied to a copy,
# which the target must fail with the failure named for it.
module ErxF2fsFuzz
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  # The modules a seeded fault may change, by name.
  TARGETS = { codec: File.join(ROOT, 'erlang/apps/erx_f2fs/src/erx_f2fs_codec.erl'),
              mount: File.join(ROOT, 'erlang/apps/erx_f2fs/src/erx_f2fs_mount.erl'),
              core: File.join(ROOT, 'erlang/apps/erx_f2fs/src/erx_f2fs_core.erl') }.freeze
  SOURCES = [File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx/src/generated/erx_abi_packed.erl'),
             *%w[erx_f2fs_codec_tests erx_f2fs_mount_tests erx_f2fs_core_tests erx_f2fs_corpus
                 erx_f2fs_fuzz].map do |name|
               File.join(ROOT, "test/erlang/#{name}.erl")
             end].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')
  INCLUDE = File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx/include')
  # Each run, inside tools/erx check-fuzz's 900 s for the target: the codec's own runs
  # every case, and a seeded fault's ends at its first failure.
  DEADLINE_SECONDS = '280'

  Seed = Data.define(:fault, :target, :anchor, :replacement, :failure) do
    def initialize(target: :codec, **fields) = super
  end

  SEEDS = [
    Seed.new(fault: 'the area-boundary rule of [F 14] dropped',
             anchor: "    check_areas(Super),\n", replacement: '', failure: 'areas'),
    Seed.new(fault: "the checkpoint header bitmaps' room check removed",
             anchor: '            require(SitBytes + NatBytes =< HeaderRoom, bitmap_room),',
             replacement: '            ok,', failure: 'crash'),
    Seed.new(fault: "the NAT journal's count bound off by one",
             anchor: '    require(Count =< ?ERX_F2FS_NAT_JOURNAL_ENTRIES, entry_count),',
             replacement: '    require(Count =< ?ERX_F2FS_NAT_JOURNAL_ENTRIES + 1, entry_count),',
             failure: 'size'),
    Seed.new(fault: "the SIT count's comparison with the map's set bits dropped",
             anchor: "    require(Valid =:= set_bits(Map), valid_map),\n",
             replacement: '', failure: 'round_trip'),
    Seed.new(fault: "a directory's hash depth read past 63",
             anchor: '    Inode#{i_current_depth := min(Depth, ?ERX_F2FS_DIR_HASH_DEPTH_MAX)};',
             replacement: '    Inode#{i_current_depth := Depth};', failure: 'current_depth'),
    Seed.new(fault: "i_extra_isize's multiple-of-4 rule dropped",
             anchor: '    require(Size rem ?ERX_F2FS_EXTRA_ISIZE_ALIGN =:= 0 andalso',
             replacement: '    require(true andalso', failure: 'round_trip'),
    Seed.new(fault: "a long name's run allowed past the last slot",
             anchor: '            require(Run =< 1 + bit_size(Bits), name_run),',
             replacement: '            ok,', failure: 'crash'),
    Seed.new(fault: "a NAT entry's node allowed outside the main area", target: :core,
             anchor: '    require(valid_block(Volume, Address), {nat, block_addr}),',
             replacement: '    ok,', failure: 'partition'),
    Seed.new(fault: "a slot's data address allowed outside the main area", target: :core,
             anchor: '    require(Address =:= ?ERX_F2FS_NULL_ADDR orelse Address =:= ?ERX_F2FS_NEW_ADDR orelse',
             replacement: '    require(true orelse', failure: 'partition'),
    Seed.new(fault: "a dentry area's slot count running past its block",
             anchor: '    8 * Bytes div (8 * (?ERX_F2FS_DIR_ENTRY_SIZE + ?ERX_F2FS_NAME_SLOT_SIZE) + 1).',
             replacement: '    8 * Bytes div (8 * (?ERX_F2FS_DIR_ENTRY_SIZE + ?ERX_F2FS_NAME_SLOT_SIZE) + 1) + 1.',
             failure: 'crash'),
    Seed.new(fault: "a summary block's entry_type written as 0",
             anchor: '                            entry_type => Type, check_sum => 0}).',
             replacement: '                            entry_type => 0 * Type, check_sum => 0}).',
             failure: 'round_trip')
  ].freeze

  module_function

  def run(seed:, cases:)
    sources = TARGETS.transform_values { |path| File.binread(path) }
    SEEDS.each do |fault|
      unless sources.fetch(fault.target).scan(fault.anchor).size == 1
        raise "no anchor for #{fault.fault} in #{TARGETS.fetch(fault.target)}"
      end
    end
    output, status = fuzz(sources, seed: seed, cases: cases)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ cases ok$/)
    SEEDS.each do |fault|
      faulty = sources.merge(fault.target => sources.fetch(fault.target).sub(fault.anchor, fault.replacement))
      output, status = fuzz(faulty, seed: seed, cases: cases)
      abort("#{fault.fault} passed:\n#{output}") if status.success? || !output.include?("fuzz failure: #{fault.failure}")
    end
    puts "erx_f2fs_codec, erx_f2fs_mount and erx_f2fs_core fail every mutated record, volume and file " \
         "cleanly over #{cases} " \
         "cases, and each of #{SEEDS.size} seeded faults fails"
  end

  # In a directory of its own, which also takes the crash dump of a failed run; sources maps each
  # target to the text it is compiled from.
  def fuzz(sources, seed:, cases:)
    Dir.mktmpdir('erx-f2fs-fuzz') do |work|
      targets = sources.map do |target, text|
        File.join(work, File.basename(TARGETS.fetch(target))).tap { |path| File.binwrite(path, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, *targets, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_f2fs_fuzz', 'run', seed.to_s, cases.to_s, CORPUS, LOCK,
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1, cases: 200_000 }
  OptionParser.new do |flags|
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
    flags.on('--cases N', Integer) { |value| options[:cases] = value }
  end.parse!
  ErxF2fsFuzz.run(**options)
end
