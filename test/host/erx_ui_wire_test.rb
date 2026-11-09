# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'

# ui.txt's binary form (docs/design-abi.md, "Widget format"), generated into
# build/gen: the EUnit cases of erx_ui_wire on stock's emulator (ERX_ERL and
# ERX_ERLC), and the parity of the Erlang encoder with the C reader. For the
# parity, erx_ui_wire_tests:corpus/3 encodes random records of every kind and
# property and writes what each means by name; the C reader, under ASan and
# UBSan, reads the stream and prints what it read by number; the names are
# mapped to numbers here through the ABI model, the generators' common
# source, and the two must agree line for line. The other way, the harness's
# writer writes random event and pixels records and says what each means by
# number, erx_ui_wire_tests:read_corpus/2 reads them and says what it read by
# name, and the two must agree the same way.
class ErxUIWireTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  GENERATED = File.join(ROOT, Erx::Generated::OUTPUT)
  MODULES = [Erx::ABI::UIWireEmitter::ERLANG_PATH, Erx::ABI::UIEmitter::ERLANG_PATH].freeze
  TESTS = File.join(ROOT, 'test/erlang/erx_ui_wire_tests.erl')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_ui_wire_harness.c')
  UI = Erx::ABI::Generator.plan(root: ROOT).schema.ui

  def test_generated_wire_cases_pass_under_eunit
    in_erlang do |work|
      output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                    'halt(case eunit:test(erx_ui_wire_tests, [verbose]) of ok -> 0; _ -> 1 end)', chdir: work)
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_c_reader_reads_what_the_erlang_encoder_writes
    in_erlang do |work|
      stream = File.join(work, 'stream')
      expected = File.join(work, 'expected')
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "erx_ui_wire_tests:corpus(\"#{stream}\", \"#{expected}\", 7), halt(0)", chdir: work)
      read, status = Open3.capture2(harness(work), stdin_data: File.binread(stream), binmode: true)
      assert status.success?, 'the C reader refused a record the Erlang encoder wrote'
      lines = File.readlines(expected, chomp: true)
      assert_operator lines.size, :>, 600
      lines.zip(read.lines(chomp: true)).each { |want, got| assert_equal numeric(want), got }
      assert_equal lines.size, read.lines.size
    end
  end

  def test_erlang_reader_reads_what_the_c_writer_writes
    in_erlang do |work|
      stream = File.join(work, 'stream')
      read = File.join(work, 'read')
      written = run!(harness(work), 'write', stream, '7', chdir: work).lines(chomp: true)
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "erx_ui_wire_tests:read_corpus(\"#{stream}\", \"#{read}\"), halt(0)", chdir: work)
      lines = File.readlines(read, chomp: true).map { |line| event_number(line) }
      assert_equal 600, written.size
      lines.zip(written).each { |got, want| assert_equal want, got }
      assert_equal written.size, lines.size
      seen = written.filter_map { |line| line.split(' ')[2].to_i if line.start_with?('event ') }.uniq.sort
      assert_equal UI.properties.select { |prop| prop.type.form == 'event' }.map(&:number).sort, seen
    end
  end

  # A valid record with one field broken, for each reason the C reader gives.
  def test_c_reader_refuses_each_broken_record_for_its_reason
    visible, placeholder, text = %w[visible placeholder text].map { |name| property(name).number }
    Dir.mktmpdir('erx-ui-wire-refusal') { |work| refusals(harness(work), visible:, placeholder:, text:) }
  end

  private

  def refusals(reader, visible:, placeholder:, text:)
    {
      [0].pack('V') => 'bad length',
      record('C', 11) => 'unknown tag',
      record('CVCC', 6, 1, 10, 0) => 'unknown tag',
      record('CV', 2, 0) => 'bad node',
      record('CVVvCC', 1, 1, 0, 0, 255, 0) => 'unknown kind',
      record('CVCCC', 3, 1, 1, 255, 0) => 'unknown property',
      record('CVCCCCCC', 3, 1, 2, visible, 1, visible, 1, 0) => 'property twice',
      record('CVCCCC', 3, 1, 1, visible, 2, 0) => 'bad value',
      record('CVCCVCCC', 3, 1, 1, placeholder, 2, 0xc0, 0x80, 0) => 'bad value',
      record('CVCCCCCVC', 3, 1, 1, text, 2, 0, 0, 0, 0) => 'bad status',
      record('CVCCCCCVC', 3, 1, 1, text, 4, 1, 0, 0, 0) => 'bad status',
      record('CVC', 3, 1, 255) => 'too many properties',
      record('CC', 8, 4) => 'unknown input form',
      record('CCCvV', 8, 2, 2, 0, 65) => 'bad key direction',
      record('CCCvV', 8, 2, 1, 0, 0xd800) => 'bad rune',
      record('CC', 5, 0) => 'bytes left over',
      record('Cv', 7, 1) => 'short record'
    }.each do |bytes, reason|
      _out, error, status = Open3.capture3(reader, stdin_data: bytes, binmode: true)
      refute status.success?, "accepted a record refused for #{reason}"
      assert_equal "refused at 0: #{reason}", error.chomp
    end
  end

  def record(format, *fields) = fields.pack(format).then { |body| [body.bytesize].pack('V') + body }

  # The harness, built with the generated C under ASan and UBSan.
  def harness(work)
    File.join(work, 'harness').tap do |binary|
      next if File.exist?(binary)

      run!(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-I', File.join(GENERATED, 'include'),
           HARNESS, File.join(GENERATED, Erx::ABI::UIWireEmitter::C_SOURCE_PATH), '-o', binary, chdir: work)
    end
  end

  # A line of read_corpus/2 with the event's name mapped to its number.
  def event_number(line)
    tokens = line.split(' ')
    tokens[2] = property(tokens[2]).number.to_s if tokens.first == 'event'
    tokens.join(' ')
  end

  def in_erlang
    Dir.mktmpdir('erx-ui-wire-test') do |work|
      sources = MODULES.map do |path|
        File.join(work, File.basename(path)).tap { |target| File.binwrite(target, File.binread(File.join(GENERATED, path))) }
      end
      run!(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *sources, TESTS, chdir: work)
      yield work
    end
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end

  # An expected line with each name the C harness prints as a number mapped
  # to it, the properties in number order, and the status block the harness
  # prints for every property added to those that carry none.
  def numeric(line)
    tokens = line.split(' ')
    case tokens.first
    when 'insert' then [*tokens[0, 4], kind(tokens[4]).number, *props(tokens.drop(5))].join(' ')
    when 'set'
      slash = tokens.index('/')
      removed = tokens.drop(slash + 1).map { |name| property(name).number }.sort
      ['set', tokens[1], *props(tokens[2...slash]), '/', *removed].join(' ')
    else line
    end
  end

  def props(tokens)
    tokens.map do |token|
      name, text = token.split('=', 2)
      prop = property(name)
      block, value = prop.status ? text.split(':', 2) : ['0,0,,0', text]
      [prop.number, "#{prop.number}=#{block}:#{wire_value(prop.type, value)}"]
    end.sort.map(&:last)
  end

  def wire_value(type, value)
    case type.form
    when 'boolean' then { 'true' => '1', 'false' => '0' }.fetch(value)
    when 'enum', 'image' then type.numbers.fetch(type.atoms.index(value)).to_s
    else value
    end
  end

  def kind(name) = UI.kinds.find { |entry| entry.name == name } || flunk("unknown kind #{name}")
  def property(name) = UI.properties.find { |entry| entry.name == name } || flunk("unknown property #{name}")
end
