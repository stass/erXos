# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'line_escape'

module Erx
  # L4Re's importer (docs/design-bench.md, "L4Re's guest"): a pure function from the
  # lines of a boot that ran ipcbench to one mean cell in cycles per asked cell. It is
  # written from ipcbench's facts record alone, and is the one reader of its lines under
  # HVF and on the board alike. Every line is the guest's, untrusted: read_line reads one
  # through bounded, anchored patterns, and nothing else looks at the text.
  #
  # Each program the comparison reads prints its lines under its log tag; its result is
  # one line "CPU <n> done <count> <word>s in <total> cpu-cycles, <mean> cpu-cycles/<word>",
  # timed over CALLS calls. An IPC program counts a call's request and reply as two IPCs,
  # so its count is twice the calls and its mean half a round trip; the cell keeps the
  # calls, the total and the mean as printed.
  module Ipcbench
    CALLS = 10_000
    # The longest line read; a longer line of a read program is unreadable.
    MAX_LINE = 256
    # A total is a difference of the 64-bit cycle counter.
    COUNTER_LIMIT = 2**64

    # A program the comparison reads: its log tag, the erXos benchmark and operation it is
    # set beside (the counterparts table of docs/design-bench.md), its result line's word
    # and the operations it counts per call.
    Program = Data.define(:tag, :benchmark, :operation, :word, :per_call) do
      def count = CALLS * per_call
    end
    PROGRAMS = [
      Program.new(tag: 'sc:single', benchmark: 'nullcall', operation: 'kernel', word: 'syscall', per_call: 1),
      Program.new(tag: 'ipc:1AS', benchmark: 'nullcall', operation: 'root-same-space', word: 'IPC', per_call: 2),
      Program.new(tag: 'ipc:2AS', benchmark: 'nullcall', operation: 'root-cross-space', word: 'IPC', per_call: 2)
    ].freeze

    # One line of a read program: a :result (its word, count, total and mean), an
    # :error, or an :unreadable line, kept escaped for the refusal that names it.
    Line = Data.define(:tag, :kind, :word, :count, :total, :mean, :text)

    # ned prints each line a program writes behind the program's log tag, cut or padded
    # to TAG_WIDTH columns and followed by "| " (sc:single as "sc:singl| "), and wraps
    # each write in the color its configuration names, so a line written in two writes
    # carries color sequences in its middle too (docs/design-bench.md, "L4Re's guest").
    TAG_WIDTH = 8
    FIELDS = PROGRAMS.to_h { |program| ["#{program.tag[0, TAG_WIDTH].ljust(TAG_WIDTH)}| ", program.tag] }.freeze
    TAGGED = /\A(?<field>#{Regexp.union(FIELDS.keys).source})/n
    # ned's color sequences: Select Graphic Rendition, ESC [ parameters m. They are
    # dropped before a line is read, and nothing else of the line is.
    COLOR = /\e\[[0-9;]{0,16}m/n
    RESULT = %r{\ACPU[ ]{1,2}\d{1,3}[ ]done[ ](?<count>\d{1,9})[ ](?<word>IPC|syscall)s[ ]in[ ](?<total>\d{1,20})
                [ ]cpu-cycles,[ ](?<mean>\d{1,20})[ ]cpu-cycles/(?<per>IPC|syscall)\z}xn
    ERROR = /\A(?:caller: ipc err|IPC error)[ -~]*\z/n

    module_function

    # The line of one of PROGRAMS that text is, or nil for a line of anything else: the
    # boot's own output, the configuration script's titles, the programs not read.
    def read_line(text)
      line = text.b.delete_suffix("\r").gsub(COLOR, '')
      tagged = TAGGED.match(line)
      return nil unless tagged

      tag = FIELDS.fetch(tagged[:field])
      body = tagged.post_match
      result = RESULT.match(body) if line.bytesize <= MAX_LINE
      if result && result[:word] == result[:per]
        Line.new(tag: tag, kind: :result, word: result[:word], count: Integer(result[:count], 10),
                 total: Integer(result[:total], 10), mean: Integer(result[:mean], 10), text: nil)
      elsif line.bytesize <= MAX_LINE && ERROR.match?(body)
        Line.new(tag: tag, kind: :error, word: nil, count: nil, total: nil, mean: nil, text: nil)
      else
        shown = LineEscape.escape(line.byteslice(0, MAX_LINE))
        shown = "#{shown}... (#{line.bytesize} bytes)" if line.bytesize > MAX_LINE
        Line.new(tag: tag, kind: :unreadable, word: nil, count: nil, total: nil, mean: nil, text: shown)
      end
    end

    # The cells of benchmark asked (BenchSuite::LandingCell values), each judged from
    # lines, and the refusal of each line the reader could not read.
    def import(lines, benchmark:, cells:)
      read = lines.filter_map { |text| read_line(text) }
      { cells: cells.map { |asked| judge(asked, benchmark: benchmark, lines: read) },
        refused: read.select { |line| line.kind == :unreadable }.map { |line| "ipcbench line #{line.text}" } }
    end

    # One asked cell: rejected when its program printed a line that is not a result or
    # an error, more than one result, or a result whose count or mean is not what the
    # program prints; failed when it printed an error; measured from its one result; and
    # not run when no line reports it.
    def judge(asked, benchmark:, lines:)
      program = PROGRAMS.find { |candidate| [candidate.benchmark, candidate.operation] == [benchmark, asked.operation] }
      return cell(asked, benchmark, 'not_run', "ipcbench has no program for #{asked.operation}") unless program

      tag = program.tag
      own = lines.select { |line| line.tag == tag }
      results = own.select { |line| line.kind == :result }
      if own.any? { |line| line.kind == :unreadable }
        cell(asked, benchmark, 'rejected', "ipcbench #{tag} printed a line it does not print")
      elsif results.size > 1
        cell(asked, benchmark, 'rejected', "ipcbench #{tag} printed more than one result")
      elsif own.any? { |line| line.kind == :error }
        cell(asked, benchmark, 'failed', "ipcbench #{tag} printed an IPC error")
      elsif results.empty?
        cell(asked, benchmark, 'not_run', "no ipcbench line reports #{tag}")
      elsif !consistent?(results.first, program)
        cell(asked, benchmark, 'rejected', "ipcbench #{tag} result is not #{program.count} #{program.word}s and their mean")
      else
        result = results.first
        cell(asked, benchmark, 'measured', nil, { 'count' => CALLS, 'total' => result.total, 'mean' => result.mean })
      end
    end
    private_class_method :judge

    # A result is its program's when it counts the program's operations in its word and
    # its mean is the total over them, truncated, on a counter of 64 bits. A total of
    # zero is a counter that did not count, not a free operation.
    def consistent?(result, program)
      result.word == program.word && result.count == program.count && result.total.positive? && result.total < COUNTER_LIMIT &&
        result.mean == result.total / result.count
    end
    private_class_method :consistent?

    def cell(asked, benchmark, status, reason, detail = {})
      BenchRecord::Cell.new(
        benchmark: benchmark, operation: asked.operation, form: 'mean', profile: nil, counts: nil,
        status: status, reason: reason, detail: detail,
        conditions: BenchRecord::Conditions.new(load: asked.load, placement: asked.placement,
                                                parameters: asked.parameters, clock: 'cycles', batch: 1)
      )
    end
    private_class_method :cell
  end
end
