#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'socket'
require 'tmpdir'

# The fuzz target of the harness's two readers of what QEMU hands the host about a guest's
# display: the PPM decoder (Erx::Ppm), whose header sizes the guest chooses, and the QMP
# client (Erx::Qmp), which reads QEMU's lines. It mutates seed pictures and seed QMP
# conversations and checks:
#
# * only Erx::Error leaves either reader, whatever the bytes;
# * the PPM decoder agrees with a reference of this file's own (a regular expression over the
#   header, written apart from the decoder's cursor code): it accepts the same inputs, with
#   the same size and the same pixel bytes, and an accepted picture's pixel bytes number
#   width * height * 3;
# * a picture file over the size limit is refused whole, and a link or a directory is no
#   picture;
# * the QMP client's read buffer never grows past the line bound plus one read, however long
#   a line QEMU sends, and each seed conversation ends as it should.
#
# The target runs the readers as they are, then a copy of them with each seeded fault applied,
# which must fail: that shows the fixed cases reach the bound each fault removes.
module Erx
  module HarnessScreenFuzz
    HERE = __dir__
    LIB = File.expand_path('../lib/erx', HERE)
    DEADLINE_SECONDS = 25

    # A seeded fault: the readers' text it replaces, its replacement, the file it is in, and
    # the text of the failure the run over the faulty copy must end with.
    Fault = Data.define(:name, :file, :anchor, :replacement, :count, :failure)
    FAULTS = [
      Fault.new(name: 'a PPM decoder with no pixel-count bound', file: 'ppm.rb',
                anchor: 'width * height <= MAX_PIXELS', replacement: 'true', count: 2,
                failure: 'took a picture the format does not allow'),
      Fault.new(name: 'a QMP reader with no line-length bound', file: 'qmp.rb',
                anchor: 'too_long = (newline || @buffer.bytesize) > MAX_LINE_BYTES', replacement: 'too_long = false',
                count: 1, failure: 'the QMP read buffer holds')
    ].freeze

    # The readers, which a fault's copy holds as files of its own. Every other file of the
    # library is linked to the original, so that nothing loads twice (the generated tables
    # behind line_escape.rb find the tree by the real path of their own files).
    READER_FILES = %w[ppm.rb qmp.rb].freeze

    # What a case did that it must not have.
    class Failure < StandardError; end

    # The numbers a mutation puts in a PPM header: the limits of the format and of its bound.
    BOUNDARY_NUMBERS = [0, 1, 2, 255, 256, 4095, 4096, 4097, 65_535, 65_536, 99_999_999, 100_000_000, 16_777_215,
                        16_777_216, 16_777_217, 4_294_967_296].freeze
    STEERING = [0, 9, 10, 13, 32, 35, 48, 57, 80, 54, 255, 0x80].freeze
    MAX_CASE_BYTES = 600

    # The readers' limits, spelled out here and not read from the readers'
    # constants, so that a reader whose constant changed is a reader the cases refuse.
    HEADER_MAX = 256
    MAX_PIXELS = 4096 * 4096
    MAX_FILE_BYTES = HEADER_MAX + (MAX_PIXELS * 3)
    LINE_BYTES = 65_536
    NESTING = 8
    EVENTS = 64

    module_function

    # ---- The PPM decoder

    PPM_WHITE = '[ \t\n\v\f\r]'
    PPM_BLANKS = "(?:#{PPM_WHITE}|\#[^\n]*(?:\n|\\z))*".freeze
    PPM_HEADER = /\AP6#{PPM_BLANKS}([0-9]{1,8})(?![0-9])#{PPM_BLANKS}([0-9]{1,8})(?![0-9])#{PPM_BLANKS}([0-9]{1,8})(?![0-9])#{PPM_WHITE}/n

    # [width, height, pixel bytes] of a picture the format allows, or nil.
    def reference_ppm(bytes)
      match = PPM_HEADER.match(bytes.b)
      return nil unless match && (1..3).all? { |index| match.begin(index) < HEADER_MAX }

      width, height, maxval = (1..3).map { |index| Integer(match[index], 10) }
      pixels = match.post_match
      return nil unless maxval == 255 && width.positive? && height.positive? && width * height <= MAX_PIXELS &&
                        pixels.bytesize == width * height * 3

      [width, height, pixels]
    end

    def ppm_seeds
      pixels = (0...12).map { |index| (index * 21) % 256 }.pack('C*')
      ["P6\n1 1\n255\n\x10\x20\x30".b, "P6\n2 2\n255\n".b + pixels,
       "P6\n# a comment\n4 1\n255\n".b + pixels, "P6\r\n2\t2\r\n255\r".b + pixels,
       "P6 1 1 255 \x00\x00\x00".b, "P6\n3 1 #c\n255\n".b + pixels.byteslice(0, 9), "P6\n1 4\n255\n".b + pixels]
    end

    def digits_at(bytes)
      bytes.to_enum(:scan, /[0-9]+/n).map { Regexp.last_match.begin(0)..(Regexp.last_match.end(0) - 1) }
    end

    # A picture the decoder takes: random pixel bytes of a random size, then the header that fits.
    def consistent_ppm(random)
      width = random.rand(1..40)
      height = random.rand(1..40)
      "P6\n#{width} #{height}\n255\n".b + random.bytes(width * height * 3)
    end

    def mutate_ppm(seed, random)
      result = seed.b.dup
      random.rand(1..3).times do
        spans = digits_at(result)
        case random.rand(5)
        when 0 then result[random.rand(result.bytesize + 1), 0] = STEERING.sample(random: random).chr.b
        when 1 then result = result.byteslice(0, random.rand(result.bytesize + 1))
        when 2 then result << random.bytes(random.rand(1..4))
        when 3 then result.setbyte(random.rand(result.bytesize), random.rand(256)) unless result.empty?
        else
          span = spans.sample(random: random)
          result[span] = BOUNDARY_NUMBERS.sample(random: random).to_s.b if span
        end
      end
      result.byteslice(0, MAX_CASE_BYTES)
    end

    def exercise_ppm(bytes)
      expected = reference_ppm(bytes)
      image = begin
        Erx::Ppm.decode(bytes)
      rescue Erx::Error
        nil
      end
      shown = bytes.byteslice(0, 40).unpack1('H*')
      if expected.nil?
        raise Failure, "decode took a picture the format does not allow: #{shown}" if image
      elsif image.nil?
        raise Failure, "decode refused a picture the format allows: #{shown}"
      else
        raise Failure, "decode disagrees with the reference on #{shown}" unless
          [image.width, image.height, image.pixels] == expected
        raise Failure, "decoded pixel bytes are not width * height * 3: #{shown}" unless
          image.pixels.bytesize == image.width * image.height * 3
        raise Failure, "a picture does not decode to itself again: #{shown}" unless Erx::Ppm.decode(image.to_ppm) == image
      end
    end

    # A picture of 1 x 1 whose last header number (maxval) starts at byte `start` of the file,
    # behind white space.
    def padded_header_ppm(start)
      head = "P6\n1 1".b
      head + (' ' * (start - head.bytesize)) + "255\n\x01\x02\x03".b
    end

    # Cases that need the header bound and the size limit, so they cannot be mutations. Each
    # goes through exercise_ppm, whose reference decides. The header's last number starting at
    # byte 255 is the last one allowed; at 256 and 257 it is refused. A run of white space or
    # a comment before the first number is no way past the bound. Numbers of 8 digits with
    # leading zeros are numbers; of 9 and 10 digits they are refused. A picture one pixel past
    # the size limit has exactly the bytes it declares.
    def exercise_ppm_limits(directory)
      [255, 256, 257].each { |start| exercise_ppm(padded_header_ppm(start)) }
      exercise_ppm("P6#{' ' * 300}1 1 255\n\x01\x02\x03".b)
      exercise_ppm("P6 ##{'c' * 300}\n1 1 255\n\x01\x02\x03".b)
      exercise_ppm("P6##{'c' * 240}\n1 1 255\n\x01\x02\x03".b)
      %w[00000255 000000255 0000000255].each { |maxval| exercise_ppm("P6\n1 1 #{maxval}\n\x01\x02\x03".b) }
      %w[00000001 000000001].each { |width| exercise_ppm("P6\n#{width} 1 255\n\x01\x02\x03".b) }
      [[4097, 4096], [1, MAX_PIXELS + 1], [MAX_PIXELS + 1, 1]].each do |width, height|
        exercise_ppm("P6\n#{width} #{height}\n255\n".b + ("\0".b * (width * height * 3)))
      end
      exercise_ppm("P6\n#{MAX_PIXELS} 2\n255\n".b)
      exercise_ppm("P6\n99999999 99999999\n255\n".b)
      exercise_ppm_file_limits(directory)
    end

    # What read_file refuses, each with the reason it must give. A file past the size limit
    # that decode alone would take: a picture of the most pixels whose header runs to byte 258,
    # so three bytes past the limit. A link. A directory. A FIFO, which the NONBLOCK open
    # reaches the stat of instead of waiting for a writer.
    def exercise_ppm_file_limits(directory)
      pixel_bytes = MAX_PIXELS * 3
      head = "P6\n4096 4096".b
      header = head + (' ' * (255 - head.bytesize)) + "255\n".b
      huge = File.join(directory, 'huge.ppm')
      File.open(huge, 'wb') do |file|
        file.write(header)
        file.truncate(header.bytesize + pixel_bytes)
      end
      raise 'the huge file is within the limit' unless File.size(huge) > MAX_FILE_BYTES

      refuse_file(huge, /larger than a picture can be/)
      File.write(File.join(directory, 'real.ppm'), ppm_seeds.first)
      File.symlink(File.join(directory, 'real.ppm'), File.join(directory, 'link.ppm'))
      refuse_file(File.join(directory, 'link.ppm'), /cannot read/)
      Dir.mkdir(File.join(directory, 'dir.ppm'))
      refuse_file(File.join(directory, 'dir.ppm'), /not a regular file/)
      File.mkfifo(File.join(directory, 'fifo.ppm'))
      refuse_file(File.join(directory, 'fifo.ppm'), /not a regular file/)
    end

    def refuse_file(path, reason)
      begin
        Erx::Ppm.read_file(path)
      rescue Erx::Ppm::FormatError => e
        return if e.message.match?(reason)

        raise Failure, "read_file refused #{File.basename(path)} for the wrong reason: #{e.message.byteslice(0, 80)}"
      end
      raise Failure, "read_file took #{File.basename(path)}, which is no picture"
    end

    def exercise_ppm_file(bytes, directory)
      path = File.join(directory, 'case.ppm')
      File.binwrite(path, bytes)
      from_file = begin
        Erx::Ppm.read_file(path)
      rescue Erx::Error
        nil
      end
      raise Failure, 'read_file and decode disagree' unless from_file == (reference_ppm(bytes) && Erx::Ppm.decode(bytes))
    end

    # ---- The QMP client

    GREETING = %({"QMP": {"version": {"qemu": {"micro": 0, "minor": 1, "major": 11}, "package": ""}, "capabilities": ["oob"]}}\n)
    EVENT = %({"timestamp": {"seconds": 1, "microseconds": 2}, "event": "RESET", "data": {"guest": true, "reason": "host-qmp-system-reset"}}\n)

    def reply(id) = %({"return": {}, "id": #{id}}\n)

    # Each seed conversation (what QEMU sends for the handshake and quit) and the outcome the
    # client must reach: :ok, :protocol (any ProtocolError), or a regexp the message of the
    # ProtocolError it raises must match.
    def qmp_seeds
      [[GREETING + reply(1) + reply(2), :ok],
       [GREETING + EVENT + reply(1) + EVENT + EVENT + reply(2), :ok],
       [GREETING + reply(1) + %({"error": {"class": "GenericError", "desc": "no"}, "id": 2}\n), :protocol],
       [GREETING + reply(1), :ok],
       [GREETING + %({"error": {"class": "CommandNotFound", "desc": "bad\\u001b[2J"}, "id": 1}\n), :protocol],
       [GREETING + reply(7), :protocol], [reply(1), :protocol], ['', :protocol],
       [GREETING + %({"return": {}, "id": 1, "id": 1}\n), :protocol],
       [GREETING + "[]\n" + reply(1), :protocol], [GREETING.chomp + reply(1), :protocol]]
    end

    # QEMU may close its end before or after answering quit, so :ok covers a closed connection
    # at quit only; every other outcome is a ProtocolError (ConnectionClosed is one).
    def run_conversation(stream, random)
      client_end, peer_end = UNIXSocket.pair
      chunks = Random.new(random.rand(2**32))
      writer = Thread.new do
        offset = 0
        while offset < stream.bytesize
          step = chunks.rand(1..5000)
          peer_end.write(stream.byteslice(offset, step))
          offset += step
        end
        # Half-close, so the client's writes still land while it reads to the end of the stream.
        peer_end.shutdown(:WR)
        peer_end.read
      rescue SystemCallError, IOError
        nil
      ensure
        peer_end.close
      end
      client = Erx::Qmp.new(client_end, directory: '/nonexistent', timeout: 5)
      outcome = begin
        client.handshake
        client.quit
        :ok
      rescue Erx::Error => e
        e
      end
      buffer = client.instance_variable_get(:@buffer)
      limit = LINE_BYTES * 2
      raise Failure, "the QMP read buffer holds #{buffer.bytesize} bytes, past #{limit}" if buffer.bytesize > limit

      outcome
    ensure
      client_end&.close
      writer&.join
    end

    def exercise_qmp_seed(stream, expected, random)
      outcome = run_conversation(stream, random)
      good = case expected
             when :ok then outcome == :ok
             when :protocol then outcome.is_a?(Erx::Qmp::ProtocolError)
             else outcome.is_a?(Erx::Qmp::ProtocolError) && outcome.message.match?(expected)
             end
      raise Failure, "conversation #{stream.byteslice(0, 60).inspect} (#{stream.bytesize} bytes) ended as #{outcome.inspect}" unless good
    end

    def exercise_qmp(stream, random) = run_conversation(stream, random)

    # A greeting line of exactly `bytes` bytes without its newline.
    def sized_greeting(bytes)
      head = '{"QMP": {"k": "'
      tail = '"}}'
      head + ('a' * (bytes - head.bytesize - tail.bytesize)) + tail
    end

    # A greeting nested `depth` deep.
    def nested_greeting(depth) = %({"QMP": {"k": #{'[' * (depth - 2)}0#{']' * (depth - 2)}}}\n)

    # Streams that need more than the case bound, at each bound and one past it. The first
    # has no newline, which only the line bound stops from filling the buffer.
    def qmp_limit_cases
      line = LINE_BYTES
      depth = NESTING
      events = EVENTS
      long = /longer than/
      [[GREETING + ('x' * (line * 5)), long],
       [sized_greeting(line * 4) + "\n" + reply(1), long],
       [sized_greeting(line) + "\n" + reply(1) + reply(2), :ok],
       [sized_greeting(line + 1) + "\n" + reply(1) + reply(2), long],
       [sized_greeting(line + 1), long],
       [nested_greeting(depth) + reply(1) + reply(2), :ok],
       [nested_greeting(depth + 1) + reply(1) + reply(2), /not JSON/],
       [GREETING + (EVENT * events) + reply(1) + reply(2), :ok],
       [GREETING + (EVENT * (events + 1)) + reply(1) + reply(2), /more than #{events} events/]]
    end

    def mutate_qmp(stream, random)
      lines = stream.b.lines
      result = stream.b.dup
      random.rand(1..3).times do
        case random.rand(6)
        when 0 then result[random.rand(result.bytesize + 1), 0] = STEERING.sample(random: random).chr.b
        when 1 then result = result.byteslice(0, random.rand(result.bytesize + 1))
        when 2 then result.setbyte(random.rand(result.bytesize), random.rand(256)) unless result.empty?
        when 3 then result << lines.sample(random: random).to_s unless lines.empty?
        when 4 then result << ('a' * random.rand(1..(LINE_BYTES * 2)))
        else result << random.bytes(random.rand(1..16)) << "\n"
        end
      end
      result
    end

    # ---- Driving

    def load_readers(lib)
      require File.join(LIB, 'line_escape')
      require File.join(lib, 'ppm')
      require File.join(lib, 'qmp')
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      count = 0
      Dir.mktmpdir('erx-harness-screen-') do |directory|
        exercise_ppm_limits(directory)
        qmp_limit_cases.each { |stream, expected| exercise_qmp_seed(stream, expected, random) }
        ppm_seeds.each { |bytes| exercise_ppm(bytes) }
        qmp_seeds.each { |stream, expected| exercise_qmp_seed(stream, expected, random) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          count += iterate(random, directory)
        end
      end
      count
    end

    def iterate(random, directory)
      streams = qmp_seeds.map(&:first)
      10.times do
        bytes = random.rand(4).zero? ? consistent_ppm(random) : mutate_ppm(ppm_seeds.sample(random: random), random)
        exercise_ppm(bytes)
        exercise_ppm_file(bytes, directory) if random.rand(8).zero?
      end
      exercise_qmp(mutate_qmp(streams.sample(random: random), random), random)
      11
    end

    # Runs the target as it is, then in a child process over each fault's copy of the readers.
    def run_with_faults(seconds:, seed:)
      count = run(seconds: seconds, seed: seed)
      FAULTS.each { |fault| refuse_fault(fault, seed) }
      puts "harness screen readers: #{count} inputs, and each of #{FAULTS.size} seeded faults fails"
    end

    def refuse_fault(fault, seed)
      Dir.mktmpdir('erx-harness-screen-fault-') do |copy|
        Dir.children(LIB).grep(/\.rb\z/).each do |name|
          source = File.join(LIB, name)
          READER_FILES.include?(name) ? FileUtils.cp(source, copy) : File.symlink(source, File.join(copy, name))
        end
        path = File.join(copy, fault.file)
        source = File.read(path)
        raise "no anchor for #{fault.name} in #{fault.file}" unless source.scan(fault.anchor).size == fault.count

        File.write(path, source.gsub(fault.anchor, fault.replacement))
        output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS.to_s, RbConfig.ruby, __FILE__,
                                         '--lib', copy, '--seconds', '1', '--seed', seed.to_s, stdin_data: '')
        abort("#{fault.name} passed:\n#{output}") if status.success?
        abort("#{fault.name} did not run (status #{status.exitstatus.inspect}):\n#{output}") unless output.include?('fuzz failure:')
        abort("#{fault.name} failed for another reason, not #{fault.failure.inspect}:\n#{output}") unless output.include?(fault.failure)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 3, seed: 1, lib: Erx::HarnessScreenFuzz::LIB }
  OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
    arguments.on('--lib DIR') { |value| options[:lib] = value }
  end.parse!(ARGV)
  raise OptionParser::InvalidArgument, 'budget of 1..60 seconds' unless options[:seconds].between?(1, 60)

  Erx::HarnessScreenFuzz.load_readers(options[:lib])
  begin
    if options[:lib] == Erx::HarnessScreenFuzz::LIB
      Erx::HarnessScreenFuzz.run_with_faults(seconds: options[:seconds], seed: options[:seed])
    else
      Erx::HarnessScreenFuzz.run(seconds: options[:seconds], seed: options[:seed])
    end
  rescue StandardError => e
    abort("fuzz failure: #{e.class}: #{e.message}")
  end
end
