# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../generated/abi'
require_relative 'runner'

module Erx
  # The harness's reader of the crash frame in a guest's serial log
  # (docs/design-kernel.md, "The root task"). Written apart from the C reader
  # in kernel/core/crash_read.c, and checked against it case by case, so a
  # disagreement is a bug in one of them.
  #
  # Every byte of the log is untrusted. The header line bounds the record
  # before a payload line is read, every refusal is a status and a reason, and
  # nothing here raises on any log. Only report makes text for a terminal, and
  # it passes everything through Terminal.escape.
  module CrashFrame
    SCHEMA = ABI::Generated::SCHEMA
    CODEC = ABI::Generated::CODEC

    BEGIN_MARKER = CODEC.fixed_bytes('crash_frame_begin').b.freeze
    END_MARKER = CODEC.fixed_bytes('crash_frame_end').b.freeze
    LINE_CHARS = CODEC.constant('crash_frame_line')
    LINE_BYTES = LINE_CHARS / 4 * 3
    CRASH_SIZE = CODEC.constant('crash_size')
    CPU_LIMIT = CODEC.constant('cpu_limit')
    BRIEF_SIZE = CODEC.layout_size('erx_crash_brief')
    RECORD_SIZE = CODEC.layout_size('erx_crash_record')
    REGS_SIZE = CODEC.layout_size('erx_regs')
    # What a report keeps of a frame that failed: a frame's own lines fit, and
    # a line that is not one cannot make the report grow with the log.
    KEPT_BYTES_MAX = 2 * CRASH_SIZE + 1024

    FORMS = { 'brief' => CODEC.member('crash_form', 'brief'), 'full' => CODEC.member('crash_form', 'full') }.freeze
    CAUSE = %w[fault halt watchdog panic].to_h { |name| [name.to_sym, CODEC.member('crash_cause', name)] }.freeze
    FAULT_KINDS = SCHEMA.types.fetch('fault_kind').members.values.freeze
    FAULT_EXIT = CODEC.member('fault_kind', 'exit')
    SLOT_NONE = CODEC.member('boot_slot', 'none')
    SLOTS = [CODEC.member('boot_slot', 'a'), CODEC.member('boot_slot', 'b')].freeze
    VALUE_UNKNOWN = CODEC.member('boot_value', 'unknown')
    VALUES_WITH_SLOT = [CODEC.member('boot_value', 'normal'), CODEC.member('boot_value', 'trial')].freeze

    # A field's offset from the generated schema, never a copied number.
    def self.offset(layout, field)
      SCHEMA.types.fetch(layout).fields.find { |member| member.name == field }.offset
    end
    private_class_method :offset

    CRC_START = offset('erx_crash_brief', 'crc') + 4
    PADDING = ((offset('erx_crash_brief', 'nframes') + 4)...offset('erx_crash_brief', 'fault')).freeze
    REGS_OFFSET = offset('erx_crash_record', 'regs')
    FRAMES_OFFSET = offset('erx_crash_record', 'frames')
    FRAMES_MAX = (RECORD_SIZE - FRAMES_OFFSET) / 8

    # status is :absent, :valid, :truncated or :corrupt; reason says why, and
    # check which test a record failed. record and text are set only when
    # valid. lines are the frame's lines as the log held them, unescaped.
    Result = Data.define(:status, :reason, :check, :length, :record, :text, :lines)
    Line = Data.define(:text, :next_offset, :terminated)

    CRC_TABLE = (0..255).map do |byte|
      8.times.reduce(byte) { |crc, _| crc.odd? ? (crc >> 1) ^ 0x82f63b78 : crc >> 1 }
    end.freeze

    module_function

    def crc32c(bytes)
      bytes.each_byte.reduce(0xffffffff) { |crc, byte| CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >> 8) } ^ 0xffffffff
    end

    # Reads the first frame of log. after, when given, is the banner: only
    # lines after the first line that holds it are looked at.
    def read(log, after: nil)
      bytes = log.b
      start = banner_end(bytes, after)
      return absent if start.nil?

      cursor = start
      while cursor < bytes.bytesize
        line = line_at(bytes, cursor)
        return read_frame(bytes, line, cursor) if header_line?(line.text)

        cursor = line.next_offset
      end
      absent
    end

    # The first thing wrong with a record, as a symbol; :ok when nothing is.
    # The order and the rules are the design's, as erx_crash_check has them.
    def check(bytes, available: bytes.bytesize)
      return :short if available < BRIEF_SIZE

      header = CODEC.decode_layout('erx_crash_brief', bytes, prefix: true)
      framing(header, available) || crc_check(header, bytes) || fields(header, bytes) || body(header, bytes) || :ok
    end

    # Lines for a terminal, each one already escaped.
    def report(result)
      head = ["crash frame: #{result.status}#{" (#{result.reason})" if result.reason}" \
              "#{" check #{result.check}" if result.check}"]
      fields = (result.record || {}).map { |name, value| "#{name}: #{value}" }
      text = (result.text || '').split("\n", -1)
      kept = result.status == :valid ? [] : result.lines
      [*head, *fields, *text, *kept].map { |line| Terminal.escape(line) }
    end

    def banner_end(bytes, banner)
      return 0 if banner.nil?

      index = bytes.index(banner.b)
      return nil if index.nil?

      newline = bytes.index("\n", index)
      newline.nil? ? bytes.bytesize : newline + 1
    end
    private_class_method :banner_end

    def absent = Result.new(status: :absent, reason: nil, check: nil, length: 0, record: nil, text: nil, lines: [].freeze)
    private_class_method :absent

    def line_at(bytes, cursor)
      newline = bytes.index("\n", cursor)
      return Line.new(text: bytes.byteslice(cursor..), next_offset: bytes.bytesize, terminated: false) if newline.nil?

      text = bytes.byteslice(cursor, newline - cursor)
      text = text.byteslice(0, text.bytesize - 1) if text.end_with?("\r")
      Line.new(text: text, next_offset: newline + 1, terminated: true)
    end
    private_class_method :line_at

    def header_line?(text) = text == BEGIN_MARKER || text.start_with?("#{BEGIN_MARKER} ")
    private_class_method :header_line?

    # Refuses what the frame's rules do not allow before any payload is read.
    def parse_header(text)
      match = /\A#{Regexp.escape(BEGIN_MARKER)} (brief|full) (0|[1-9][0-9]{0,4})\z/n.match(text)
      return nil if match.nil?

      length = match[2].to_i
      legal = match[1] == 'brief' ? length == BRIEF_SIZE : length.between?(RECORD_SIZE, CRASH_SIZE)
      legal ? [FORMS.fetch(match[1]), length] : nil
    end
    private_class_method :parse_header

    def read_frame(bytes, header_line, start)
      refuse = lambda do |status, reason, finish, length: 0, check: nil|
        kept = bytes.byteslice(start, [finish - start, KEPT_BYTES_MAX].min).lines.map(&:freeze).freeze
        Result.new(status: status, reason: reason, check: check, length: length, record: nil, text: nil, lines: kept)
      end
      return refuse.call(:truncated, :cut, header_line.next_offset) unless header_line.terminated

      form, length = parse_header(header_line.text)
      return refuse.call(:corrupt, :header, header_line.next_offset) if form.nil?

      read_payload(bytes, header_line.next_offset, length, refuse) do |record, finish|
        finish_record(record, form, length, finish, refuse)
      end
    end
    private_class_method :read_frame

    def read_payload(bytes, cursor, length, refuse)
      count = (length + LINE_BYTES - 1) / LINE_BYTES
      record = String.new(capacity: length, encoding: Encoding::BINARY)
      count.times do |index|
        line = line_at(bytes, cursor)
        cursor = line.next_offset
        raw = [length - index * LINE_BYTES, LINE_BYTES].min
        problem = payload_problem(line, raw)
        return refuse.call(*problem, cursor, length: length) if problem

        record << line.text.unpack1('m0')
      end
      line = line_at(bytes, cursor)
      cursor = line.next_offset
      return refuse.call(:truncated, :cut, cursor, length: length) unless line.terminated
      return refuse.call(:corrupt, :second_header, cursor, length: length) if header_line?(line.text)
      return refuse.call(:corrupt, :no_end, cursor, length: length) unless line.text == END_MARKER

      yield record, cursor
    end
    private_class_method :read_payload

    def payload_problem(line, raw)
      return %i[truncated cut] unless line.terminated
      return %i[truncated early_end] if line.text == END_MARKER
      return %i[corrupt second_header] if header_line?(line.text)
      return %i[corrupt line_length] unless line.text.bytesize == (raw + 2) / 3 * 4

      decoded = begin
        line.text.unpack1('m0')
      rescue ArgumentError
        nil
      end
      decoded&.bytesize == raw ? nil : %i[corrupt base64]
    end
    private_class_method :payload_problem

    def finish_record(record, form, length, finish, refuse)
      failed = check(record)
      if failed == :ok
        header = CODEC.decode_layout('erx_crash_brief', record, prefix: true)
        failed = :form unless header.fetch('form') == form
        failed = :length if failed == :ok && header.fetch('length') != length
      end
      return refuse.call(:corrupt, :record, finish, length: length, check: failed) unless failed == :ok

      Result.new(status: :valid, reason: nil, check: :ok, length: length, record: decode_valid(record), text: text_of(record),
                 lines: [].freeze)
    end
    private_class_method :finish_record

    def decode_valid(record)
      return CODEC.decode_layout('erx_crash_brief', record, prefix: true) if record.bytesize == BRIEF_SIZE

      full = CODEC.decode_layout('erx_crash_record', record, prefix: true)
      full.fetch('header').merge('regs' => full.fetch('regs'), 'frames' => full.fetch('frames')).freeze
    end
    private_class_method :decode_valid

    def text_of(record)
      record.bytesize > RECORD_SIZE ? record.byteslice(RECORD_SIZE..).freeze : ''
    end
    private_class_method :text_of

    def framing(header, available)
      return :magic unless header.fetch('magic') == CODEC.constant('crash_magic')
      return :version unless header.fetch('version') == CODEC.constant('crash_version')

      length = header.fetch('length')
      case header.fetch('form')
      when FORMS.fetch('brief') then return :length unless length == BRIEF_SIZE
      when FORMS.fetch('full') then return :length unless length.between?(RECORD_SIZE, CRASH_SIZE)
      else return :form
      end
      length > available ? :short : nil
    end
    private_class_method :framing

    def crc_check(header, bytes)
      covered = bytes.byteslice(CRC_START, header.fetch('length') - CRC_START)
      crc32c(covered) == header.fetch('crc') ? nil : :crc
    end
    private_class_method :crc_check

    def boot_pair?(value, slot)
      return slot == SLOT_NONE if value == VALUE_UNKNOWN

      VALUES_WITH_SLOT.include?(value) && SLOTS.include?(slot)
    end
    private_class_method :boot_pair?

    def fields(header, bytes)
      cause = header.fetch('cause')
      return :cause unless CAUSE.value?(cause)
      return :cpu unless header.fetch('cpu') < CPU_LIMIT
      return :boot unless boot_pair?(header.fetch('boot_value'), header.fetch('boot_slot'))
      return :padding unless zero?(bytes.byteslice(PADDING.begin, PADDING.size))

      full = header.fetch('form') == FORMS.fetch('full')
      nframes = header.fetch('nframes')
      return :nframes if nframes > FRAMES_MAX || (nframes != 0 && !(full && cause == CAUSE.fetch(:panic)))

      fault_fits?(cause, header.fetch('fault')) ? nil : :fault
    end
    private_class_method :fields

    def fault_fits?(cause, fault)
      case cause
      when CAUSE.fetch(:fault) then FAULT_KINDS.include?(fault.fetch('kind'))
      when CAUSE.fetch(:halt) then fault.fetch('kind') == FAULT_EXIT
      when CAUSE.fetch(:watchdog) then fault.values.all?(&:zero?)
      else true
      end
    end
    private_class_method :fault_fits?

    def body(header, bytes)
      return nil unless header.fetch('form') == FORMS.fetch('full')

      cause = header.fetch('cause')
      unless [CAUSE.fetch(:fault), CAUSE.fetch(:panic)].include?(cause)
        return :regs unless zero?(bytes.byteslice(REGS_OFFSET, REGS_SIZE))
      end
      unused = FRAMES_OFFSET + header.fetch('nframes') * 8
      return :frames unless zero?(bytes.byteslice(unused, RECORD_SIZE - unused))

      text = bytes.byteslice(RECORD_SIZE, header.fetch('length') - RECORD_SIZE)
      text.match?(/\A[\x20-\x7e\n]*\z/n) ? nil : :text
    end
    private_class_method :body

    def zero?(bytes) = bytes.each_byte.all?(&:zero?)
    private_class_method :zero?
  end
end
