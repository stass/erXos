# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the host link's deframer, erx_hostlink_frame and erx_hostlink_stream's
# receiver (test/erlang/erx_hostlink_frame_fuzz.erl), compiled from source and run on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's) with test/erlang/host_bytes/erx_bytes.erl
# standing in for the CRC NIF. Its seeds are the shared vectors of
# test/fixtures/hostlink_frames.txt. It runs the modules as they are, then copies with one
# fault each that the target must catch: a deframer that keeps a frame a byte longer than
# 8,300 encoded bytes, which its runs at the bound catch; a deframer that takes a frame
# whatever its CRC, which its flipped bytes catch; and a receiver that takes a piece with
# MORE set of any size, which its cut bodies catch (docs/design-live.md, "Verification and
# testing").
module ErxHostlinkFrameFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCE_DIR = File.join(ROOT, 'erlang/apps/erx_hostlink/src')
  FRAME_SOURCE = File.join(SOURCE_DIR, 'erx_hostlink_frame.erl')
  STREAM_SOURCE = File.join(SOURCE_DIR, 'erx_hostlink_stream.erl')
  SOURCES = [File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl'), File.join(SOURCE_DIR, 'erx_hostlink_payload.erl'),
             File.join(ROOT, 'test/erlang/erx_hostlink_frame_fuzz.erl')].freeze
  VECTORS = File.join(ROOT, 'test/fixtures/hostlink_frames.txt')
  BOUND = '-define(ENCODED_MAX, ?ERX_HOSTLINK_ENCODED_MAX).'
  LONGER = '-define(ENCODED_MAX, (?ERX_HOSTLINK_ENCODED_MAX + 1)).'
  CRC = 'case erx_bytes:crc32c(0, Covered) of'
  NO_CRC = 'case Crc of'
  FULL_PIECE = 'byte_size(Piece) =:= ?PIECE_MAX andalso Got + ?PIECE_MAX < Total'
  ANY_PIECE = 'Got + byte_size(Piece) < Total'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    frame = File.binread(FRAME_SOURCE)
    stream = File.binread(STREAM_SOURCE)
    [BOUND, CRC].each { |text| raise "no #{text} in #{FRAME_SOURCE}" unless frame.include?(text) }
    raise "no #{FULL_PIECE} in #{STREAM_SOURCE}" unless stream.include?(FULL_PIECE)

    output, status = fuzz(frame, stream, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ frames taken, \d+ messages$/)
    { 'a deframer with a bound a byte longer' => [frame.sub(BOUND, LONGER), stream],
      'a deframer with no CRC check' => [frame.sub(CRC, NO_CRC), stream],
      'a receiver taking pieces of any size' => [frame, stream.sub(FULL_PIECE, ANY_PIECE)] }.each do |fault, texts|
      output, status = fuzz(*texts, seed: seed)
      abort("#{fault} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts 'the host link deframer and receiver agree with their references, and three faulty copies do not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(frame_text, stream_text, seed:)
    Dir.mktmpdir('erx-hostlink-frame-fuzz') do |work|
      paths = { 'erx_hostlink_frame.erl' => frame_text, 'erx_hostlink_stream.erl' => stream_text }.map do |name, text|
        File.join(work, name).tap { |path| File.binwrite(path, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', File.join(ROOT, 'erlang/apps/erx/include'),
                                       '-o', work, *paths, *SOURCES, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e({ 'ERX_HOSTLINK_VECTORS' => VECTORS }, 'gtimeout', '-k', '10', DEADLINE_SECONDS,
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_hostlink_frame_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxHostlinkFrameFuzz.run(seed: seed)
end
