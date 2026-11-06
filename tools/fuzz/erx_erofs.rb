# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_erofs, the EROFS reader, and erx_verity, its funnel
# (test/erlang/erx_erofs_fuzz.erl): the fixture images mkfs.erofs wrote read as the
# tree they were made from, and mutations of them, the superblock's checksum mostly
# fixed up, fail each operation with an error and a diagnostic, never a crash or an
# unbounded read. Compiled from source and run on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's). It runs the reader as it is, then each seeded fault applied
# to a copy, which the target must fail with the failure named for it: that shows
# the cases reach the code each fault breaks and the properties read what they claim.
module ErxErofsFuzz
  ROOT = File.expand_path('../..', __dir__)
  PRELOADED = File.join(ROOT, 'otp/erts/preloaded/src')
  READER = File.join(PRELOADED, 'erx_erofs.erl')
  SOURCES = [File.join(PRELOADED, 'erx_verity.erl'),
             *%w[erx_erofs_tests erx_erofs_fuzz].map { |name| File.join(ROOT, "test/erlang/#{name}.erl") }].freeze
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')
  DEADLINE_SECONDS = '300'

  # A fault, the text of erx_erofs it replaces and the replacement, and the failure the
  # target must report for it.
  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "a reader that does not bound a directory entry's name by its block",
             anchor: '(Start < End andalso End =< byte_size(Bytes))',
             replacement: '(Start =/= End)', failure: 'crash'),
    Seed.new(fault: 'a reader whose search over directory blocks goes the wrong way past a block',
             anchor: 'Name > Last -> search_blocks(Fs, Dir, Name, Middle + 1, High);',
             replacement: 'Name > Last -> search_blocks(Fs, Dir, Name, Low, Middle - 1);', failure: 'mismatch'),
    Seed.new(fault: "a reader that skips the superblock's checksum",
             anchor: 'orelse checksum_matches(Block0)', replacement: 'orelse true', failure: 'crc'),
    Seed.new(fault: 'a reader that walks any number of names',
             anchor: 'walk(Fs, Names) when length(Names) =< ?ERX_NS_NAMES_MAX ->',
             replacement: 'walk(Fs, Names) ->', failure: 'names_bound'),
    Seed.new(fault: "a reader that drops a malformed image's diagnostic",
             anchor: '_ = Log(diagnostic(Text, Args)),', replacement: '_ = {Log, Text, Args},',
             failure: 'silent_eio')
  ].freeze

  module_function

  def run(seed:)
    source = File.binread(READER)
    SEEDS.each do |fault|
      raise "no anchor for #{fault.fault} in #{READER}" unless source.scan(fault.anchor).size == 1
    end

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ images ok$/)
    SEEDS.each do |fault|
      output, status = fuzz(source.sub(fault.anchor, fault.replacement), seed: seed)
      abort("#{fault.fault} passed:\n#{output}") if status.success? || !output.include?("fuzz failure: #{fault.failure}")
    end
    puts "erx_erofs reads its fixtures as their tree and fails every mutated image cleanly, " \
         "and each of #{SEEDS.size} seeded faults fails"
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(reader_text, seed:)
    Dir.mktmpdir('erx-erofs-fuzz') do |work|
      reader = File.join(work, 'erx_erofs.erl')
      File.binwrite(reader, reader_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, reader, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES }, 'gtimeout', '-k', '10', DEADLINE_SECONDS,
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-run', 'erx_erofs_fuzz', 'run', seed.to_s,
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxErofsFuzz.run(seed: seed)
end
