# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative 'package_seeds'

# The fuzz target of erx_pkg_header, the package decoder (test/erlang/erx_pkg_header_fuzz.erl):
# well-formed package files written through the ABI codec (Erx::PackageSeeds), Erlang and
# native, over images of 1, 3 and 129 blocks, and mutations of them, decode without a
# crash, and every file accepted has the shape the decoder promises. Compiled from source
# and run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the decoder as
# it is, then each seeded fault applied to a copy, which the target must fail with the
# failure named for it: that shows the mutations reach each check and the properties read
# what they claim.
module ErxPkgHeaderFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  DECODER = File.join(ROOT, 'erlang/apps/erx/src/erx_pkg_header.erl')
  SOURCES = [File.join(ROOT, 'otp/erts/preloaded/src/erx_verity_tree.erl'),
             File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_abi_reader.erl'),
             File.join(ROOT, 'test/erlang/erx_pkg_header_fuzz.erl')].freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  DEADLINE_SECONDS = '300'
  # Image sizes and the tree each takes: 128 hashes to a block.
  IMAGES = { 1 => 0, 3 => 1, 129 => 3 }.freeze

  # A fault, the text of erx_pkg_header it replaces and the replacement, and the failure
  # the target must report for it.
  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "a decoder that takes the header's tree length as written",
             anchor: 'check(TreeBlocks =:= WantTree,', replacement: 'check(is_integer(WantTree),', failure: 'tree'),
    Seed.new(fault: 'a decoder whose file may run on past the tree',
             anchor: 'check(Length =:= End,', replacement: 'check(Length >= End,', failure: 'length'),
    Seed.new(fault: 'a decoder that skips the padding',
             anchor: 'check(Padding =:= <<0:(byte_size(Padding) * 8)>>,', replacement: 'check(is_binary(Padding),',
             failure: 'padding'),
    Seed.new(fault: "a decoder that does not bound the image's boundary by the bytes read",
             anchor: 'check(ImageOffset =< byte_size(Bytes), {header, short}),', replacement: '',
             failure: 'crash'),
    Seed.new(fault: 'a decoder that takes the bytes read for as many as the file has',
             anchor: 'check(byte_size(Read) >= Want, {header, short}),', replacement: '', failure: 'crash')
  ].freeze

  module_function

  def run(seed:)
    source = File.binread(DECODER)
    SEEDS.each do |fault|
      raise "no anchor for #{fault.fault} in #{DECODER}" unless source.scan(fault.anchor).size == 1
    end

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ inputs ok, [1-9]\d* accepted$/)
    SEEDS.each do |fault|
      output, status = fuzz(source.sub(fault.anchor, fault.replacement), seed: seed)
      abort("#{fault.fault} passed:\n#{output}") if status.success? || !output.include?("fuzz failure: #{fault.failure}")
    end
    puts "erx_pkg_header decodes its seeds and every mutation cleanly, and each of #{SEEDS.size} seeded faults fails"
  end

  def samples
    [Erx::PackageSeeds::ERLANG, Erx::PackageSeeds::NATIVE].product(IMAGES.to_a).map do |declaration, (image, tree)|
      Erx::PackageSeeds.sample("#{declaration.name}_#{image}", declaration: declaration,
                                                             image_blocks: image, tree_blocks: tree)
    end
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(decoder_text, seed:)
    Dir.mktmpdir('erx-pkg-header-fuzz') do |work|
      seeds = samples.map do |sample|
        File.binwrite(File.join(work, "#{sample.name}.bin"), sample.prefix)
        "{\"#{sample.name}.bin\", #{sample.length}}.\n"
      end
      File.write(File.join(work, 'seeds.term'), seeds.join)
      decoder = File.join(work, 'erx_pkg_header.erl')
      File.binwrite(decoder, decoder_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, decoder, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e({ 'ERX_PKG_SEEDS' => work }, 'gtimeout', '-k', '10', DEADLINE_SECONDS,
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-run', 'erx_pkg_header_fuzz', 'run', seed.to_s,
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxPkgHeaderFuzz.run(seed: seed)
end
