# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/prog_profile_frames'

# The event executor's decisions on a program's inbound lane (liberx/program/inbound.h),
# through test/fixtures/prog_inbound_driver.c under the address and undefined sanitizers:
# every record header of the grid below against the rule written here, the startup message
# first and reports after it (docs/design-programs.md, "The program protocol"), and each
# report of the profile read to its pipe end and the capabilities it installed, which the
# executor closes for an end the program does not hold. Each seeded fault must fail its case.
class ProgInboundTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INBOUND = 'liberx/program/inbound.c'
  SOURCES = ['liberx/erx_profile.c', 'liberx/erx_etf.c', 'kernel/crypto/blake3/blake3.c',
             'kernel/crypto/blake3/blake3_portable.c', 'build/gen/liberx/generated/prog_profile.c',
             'test/fixtures/prog_inbound_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  E = ProgProfileFrames::Etf

  REC_FRAME = 1
  FRAME_MAX = 196_608
  REPORT_BYTES = 512
  KINDS = [0, REC_FRAME, 2, 3, 4, 0xffff_ffff].freeze
  ZEROS = [0, 1, 1 << 63].freeze
  LENS = [0, 1, REPORT_BYTES - 1, REPORT_BYTES, REPORT_BYTES + 1, FRAME_MAX, FRAME_MAX + 1, 0xffff_ffff].freeze
  GRID = [false, true].product(KINDS, ZEROS, LENS).freeze

  # The rule: a frame record with a zero word of 0 and a body; the first within the profile's
  # frame bound is the startup message, every later one within the report bound a report.
  def self.decision(started, kind, zero, len)
    return 'refuse' unless kind == REC_FRAME && zero.zero? && len.positive?
    return (len <= FRAME_MAX ? 'start' : 'refuse') unless started

    len <= REPORT_BYTES ? 'report' : 'refuse'
  end

  def self.report(*body) = E.frame(E.tuple(E.atom('erx_prog'), E.small(1), body.size == 1 ? body.first : E.tuple(*body)))

  BIG_CAP = 1 << 40
  # name => [frame, answer]: which, pipe, end and the capabilities to close, or refused.
  REPORTS = {
    writer: [report(E.atom('pipe_writer'), E.small(3), E.small(4), E.small(2), E.small(100), E.small(101),
                    E.int(16_384), E.small_big(BIG_CAP), E.atom('open')),
             "report 0 3 4 100 101 #{BIG_CAP}"],
    writer_gone: [report(E.atom('pipe_writer_gone'), E.small(3), E.small(4), E.small(2)), 'report 1 3 4'],
    reader: [report(E.atom('pipe_reader'), E.small(3), E.small(4), E.small(63), E.small(7), E.atom('gone')),
             'report 2 3 4 7'],
    reader_gone: [report(E.atom('pipe_reader_gone'), E.small(3), E.small(4), E.small(0)), 'report 3 3 4'],
    lost: [report(E.atom('pipe_lost'), E.small(3), E.small(4)), 'report 4 3 4'],
    server_lost: [report(E.atom('pipe_server_lost')), 'report 5 0 0'],
    # The profile refuses these whole: a size other than the two, one capability named twice,
    # a read end index past 63, and a report the profile does not name.
    bad_size: [report(E.atom('pipe_writer'), E.small(3), E.small(4), E.small(2), E.small(100), E.small(101),
                      E.int(1000), E.small(102), E.atom('open')), 'report refused'],
    twice: [report(E.atom('pipe_writer'), E.small(3), E.small(4), E.small(2), E.small(100), E.small(100),
                   E.int(16_384), E.small(102), E.atom('open')), 'report refused'],
    rix: [report(E.atom('pipe_reader_gone'), E.small(3), E.small(4), E.small(64)), 'report refused'],
    unknown: [report(E.atom('pipe_moved'), E.small(3), E.small(4)), 'report refused']
  }.freeze

  def test_every_header_decides_as_the_rule
    answers = run_driver(File.join(ROOT, INBOUND), open_requests)
    expected = GRID.map { |started, kind, zero, len| "open #{self.class.decision(started, kind, zero, len)}" }
    assert_equal expected.size, answers.size
    GRID.zip(answers, expected).each do |(started, kind, zero, len), got, want|
      assert_equal want, got, "started=#{started} kind=#{kind} zero=#{zero} len=#{len}"
    end
  end

  def test_each_report_reads_to_its_end_and_capabilities
    answers = run_driver(File.join(ROOT, INBOUND), report_requests)
    REPORTS.each_value.zip(answers).each_with_index do |((_, want), got), at|
      assert_equal want, got, REPORTS.keys[at].to_s
    end
  end

  # A seeded fault, the requests that catch it, and the edit that plants it.
  MUTANTS = {
    'a nonzero zero word is admitted' => [:open, 'zero != 0', '(zero & 0) != 0'],
    'a report at the bound is refused' => [:open, 'len <= ERX_PROG_REPORT_BYTES', 'len < ERX_PROG_REPORT_BYTES'],
    "a writer's doorbell is left open" => [:report, "\t\treturn (3);\n", "\t\treturn (2);\n"]
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, INBOUND))
    Dir.mktmpdir('erx-prog-inbound-mutant-') do |directory|
      MUTANTS.each do |name, (requests, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
        path = File.join(directory, "#{name.tr(' ', '-').delete("'")}.c")
        File.write(path, source.sub(original, replacement))
        answers = run_driver(path, requests == :open ? open_requests : report_requests)
        expected = requests == :open ? open_expected : REPORTS.values.map(&:last)
        refute_equal expected, answers, "seeded fault not caught: #{name}"
      end
    end
  end

  private

  def open_requests = GRID.map { |started, kind, zero, len| "open #{started ? 1 : 0} #{kind} #{zero} #{len}" }
  def open_expected = GRID.map { |started, kind, zero, len| "open #{self.class.decision(started, kind, zero, len)}" }
  def report_requests = REPORTS.values.map { |frame, _| "report #{frame.unpack1('H*')}" }

  def run_driver(inbound, requests)
    Dir.mktmpdir('erx-prog-inbound-') do |directory|
      binary = File.join(directory, 'driver')
      input = File.join(directory, 'requests')
      File.write(input, "#{requests.join("\n")}\n")
      sources = [inbound, *SOURCES.map { |path| File.join(ROOT, path) }]
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                  '-I', File.join(ROOT, 'kernel/crypto')]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes, *sources, '-o', binary)
      assert status.success?, output
      output, status = Open3.capture2e(binary, input)
      assert status.success?, output
      output.lines.map(&:chomp)
    end
  end
end
