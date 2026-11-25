# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'
require_relative '../../test/fixtures/probe_volumes'

# The fuzz target of the probe of a volume's format, erx_media_probe
# (test/erlang/erx_media_probe_fuzz.erl, docs/design-drives.md "Fuzz targets"), compiled
# from source with the FAT server's boot-sector decoder and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build, over one
# volume of each format as its seeds. It runs the probe as it is, then with a decoder
# that divides by a BIOS parameter block's sizes unchecked, which must fail: a mutated
# block of a zero size then raises.
module ErxMediaProbeFuzz
  ROOT = File.expand_path('../..', __dir__)
  DECODER = 'erlang/apps/erx_fat/src/erx_fat_read.erl'
  SOURCES = %w[erlang/apps/erx_media/src/erx_media_probe.erl test/erlang/erx_media_probe_tests.erl
               test/erlang/erx_media_probe_fuzz.erl].freeze
  CHECKED = 'when BytesPerSector =:= 0; PerCluster =:= 0 ->'
  UNCHECKED = 'when false ->'
  DEADLINE_SECONDS = '300'
  VERDICT = 'raised'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    decoder = File.binread(File.join(ROOT, DECODER))
    raise "no zero-size check in #{DECODER}" unless decoder.scan(CHECKED).size == 1

    Dir.mktmpdir('erx-probe-volumes') do |volumes|
      ProbeVolumes.write(volumes)
      output, status = fuzz(decoder, seed: seed, volumes: volumes)
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ selected a format$/)
      puts output.lines.grep(/^fuzz:/)
      output, status = fuzz(decoder.sub(CHECKED, UNCHECKED), seed: seed, volumes: volumes)
      abort("a decoder dividing by unchecked sizes passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    end
    puts 'erx_media_probe never raises on a crafted volume, and the unchecked decoder does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(decoder_text, seed:, volumes:)
    Dir.mktmpdir('erx-media-probe-fuzz') do |work|
      decoder_path = File.join(work, File.basename(DECODER))
      File.binwrite(decoder_path, decoder_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work,
                            sources: [decoder_path, *SOURCES.map { |source| File.join(ROOT, source) }], include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_media_probe_fuzz', 'run', seed.to_s, volumes, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMediaProbeFuzz.run(seed: seed)
end
