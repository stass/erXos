# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
# Erx::ManifestSeeds builds its prefix seeds with Erx::PackFuzz.
require_relative 'run_pack'
require_relative 'manifest_seeds'
require_relative '../lib/erx/generated'

# The fuzz target of erx_manifest, the generated Erlang reader of the system manifest,
# run differentially against the generated C reader on the same bytes. The corpus is the
# manifest seeds and seeded mutations of them; the C reader (tools/fuzz/manifest_verdicts.c,
# under AddressSanitizer and UBSan) and the Erlang reader (test/erlang/erx_manifest_fuzz.erl,
# on stock's emulator, ERX_ERL and ERX_ERLC) each give one verdict per manifest, accepted or
# refused, and the two must agree on every one; the reason each gives is shown, not compared,
# since the readers check in different orders. Decoded values are not compared. It then runs a
# copy of the Erlang reader that admits reserved bits set in an integer field, which must
# disagree: that shows the corpus reaches the reader's field checks and the comparison reads
# the verdicts.
module ErxManifestFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated/erx_manifest.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_manifest_fuzz.erl')
  # The C reader's verdict program links the libFuzzer target's own sources, includes and
  # macros (tools/fuzz/manifest_target.rb), with a main of its own beside them.
  TARGET = Erx::PackFuzz.targets.to_h { |target| [target.kind, target] }.fetch('manifest')
  VERDICTS_SOURCE = 'tools/fuzz/manifest_verdicts.c'
  RESERVED = 'ensure((Unsigned band maps:get(zero, Field)) =:= 0,'
  WRONG_RESERVED = 'ensure((Unsigned band maps:get(zero, Field)) >= 0,'
  INPUTS = 20_000
  RECORD_MAX = 32_768
  DEADLINE_SECONDS = '300'
  BOUNDARY_WORDS = [0, 1, 2, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff].freeze
  BOUNDARY_BYTES = [0, 1, 0x7f, 0x80, 0xff].freeze

  # Seeded mutations of the seeds: each input is one seed with one to four edits.
  module Corpus
    module_function

    def build(seeds, random:, count:)
      originals = seeds.values.reject(&:empty?)
      mutants = Array.new(count - seeds.size) do
        Array.new(random.rand(1..4)).reduce(originals.sample(random: random)) { |bytes, _| edit(bytes, random) }
      end
      [*seeds.values, *mutants].map { |bytes| bytes.byteslice(0, RECORD_MAX) }
    end

    def edit(bytes, random)
      return bytes + random.bytes(random.rand(1..16)) if bytes.empty?

      at = random.rand(bytes.bytesize)
      case random.rand(6)
      when 0 then replaced(bytes, at, [bytes.getbyte(at) ^ (1 << random.rand(8))].pack('C'))
      when 1 then replaced(bytes, at, [BOUNDARY_BYTES.sample(random: random)].pack('C'))
      when 2 then replaced(bytes, at & ~3, [word(bytes, random)].pack('V'))
      when 3 then bytes.byteslice(0, at)
      when 4 then bytes + random.bytes(random.rand(1..16))
      else replaced(bytes, random.rand(bytes.bytesize), bytes.byteslice(at, random.rand(1..64)))
      end
    end

    def word(bytes, random)
      [*BOUNDARY_WORDS, bytes.bytesize, bytes.bytesize - 1, random.rand(1 << 32)].sample(random: random)
    end

    # Bytes with Patch written over them at Offset, never growing them.
    def replaced(bytes, offset, patch)
      kept = patch.byteslice(0, [bytes.bytesize - offset, 0].max)
      bytes.byteslice(0, offset) + kept + bytes.byteslice(offset + kept.bytesize..)
    end
  end

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no reserved-bits check in #{MODULE_SOURCE}" unless source.include?(RESERVED)

    Dir.mktmpdir('erx-manifest-fuzz') do |work|
      corpus = File.join(work, 'corpus.bin')
      inputs = Corpus.build(Erx::ManifestSeeds.all, random: Random.new(seed), count: INPUTS)
      File.binwrite(corpus, inputs.map { |bytes| [bytes.bytesize].pack('N') + bytes }.join)
      expected = c_verdicts(work, corpus)
      found = erlang_verdicts(work, corpus, source)
      abort(disagreements(inputs, expected, found)) unless outcomes(found) == outcomes(expected)
      wrong = erlang_verdicts(work, corpus, source.sub(RESERVED, WRONG_RESERVED))
      abort('a reader admitting reserved bits agreed with the C reader') if outcomes(wrong) == outcomes(expected)
      accepted = expected.count("ok\n")
      puts "erx_manifest agrees with the C reader on #{inputs.size} manifests (#{accepted} accepted), " \
           'and a reader admitting reserved bits does not'
    end
  end

  def c_verdicts(work, corpus)
    program = File.join(work, 'manifest-verdicts')
    output, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror',
                                     '-pedantic', '-O1', '-g', '-fsanitize=address,undefined',
                                     '-fno-sanitize-recover=undefined', '-fno-omit-frame-pointer',
                                     *Erx::PackFuzz.define_flags(TARGET),
                                     *Erx::PackFuzz.include_flags(TARGET, root: ROOT),
                                     *Erx::PackFuzz.source_paths(TARGET, root: ROOT), File.join(ROOT, VERDICTS_SOURCE),
                                     '-o', program,
                                     stdin_data: '')
    raise output unless status.success?

    output, error, status = Open3.capture3('gtimeout', '-k', '10', DEADLINE_SECONDS, program, corpus, stdin_data: '')
    abort("the C reader failed:\n#{error}") unless status.success? && error.empty?
    output.lines
  end

  # The Erlang reader's verdicts, from module_text compiled in a directory of its own.
  def erlang_verdicts(work, corpus, module_text)
    Dir.mktmpdir('erlang', work) do |directory|
      module_path = File.join(directory, 'erx_manifest.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', directory, module_path, TARGET_SOURCE,
                                       stdin_data: '')
      raise output unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', directory, '-run', 'erx_manifest_fuzz', 'run', corpus,
                                       '-s', 'init', 'stop', chdir: directory, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ manifests read$/)
      File.binread(File.join(directory, 'erlang-verdicts.txt')).lines
    end
  end

  # Accepted or refused: the readers check in different orders, so a manifest with two
  # faults may be refused by each for a different one.
  def outcomes(verdicts) = verdicts.map { |line| line.to_s.split.first }

  def disagreements(inputs, expected, found)
    differing = expected.each_index.reject { |index| outcomes([expected[index]]) == outcomes([found[index]]) }
    shown = differing.first(8).map do |index|
      "input #{index} (#{inputs[index].bytesize} bytes): C #{expected[index]&.chomp}, Erlang #{found[index]&.chomp}"
    end
    "erx_manifest disagrees with the C reader on #{differing.size} of #{inputs.size} manifests:\n#{shown.join("\n")}"
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxManifestFuzz.run(seed: seed)
end
