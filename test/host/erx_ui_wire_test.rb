# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/web_stage'

# ui.txt's binary form (docs/design-abi.md, "Widget format"), generated into
# build/gen: the EUnit cases of erx_ui_wire on stock's emulator (ERX_ERL and
# ERX_ERLC), and the parity of the three readers and writers. For the
# readers of the server's records, erx_ui_wire_tests:corpus/3 encodes random
# records of every kind and property, reads them back with the Erlang reader
# and writes what it read by name; the C reader, under ASan and UBSan, reads
# the same stream and prints what it read by number, and the TypeScript
# reader of web/test/ui_wire_harness.ts by name; the names are mapped to
# numbers here through the ABI model, the generators' common source, and the
# three must agree line for line, on the corpus and on its mutants. The
# TypeScript writer writes each record it read back to the Erlang encoder's
# bytes. The other way, the C and TypeScript harnesses' writers write
# random event and damage records and say what each means, by number from C
# and by name from TypeScript; erx_ui_wire_tests:read_corpus/2 reads them and
# says what it read by name, and the two must agree the same way.
class ErxUIWireTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  GENERATED = File.join(ROOT, Erx::Generated::OUTPUT)
  TESTS = %w[test/erlang/erx_ui_wire_tests.erl].freeze
  HARNESS = File.join(ROOT, 'test/fixtures/erx_ui_wire_harness.c')
  UI = Erx::ABI::Generator.plan(root: ROOT).schema.ui

  def test_generated_wire_cases_pass_under_eunit
    in_erlang do |work|
      output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                    'halt(case eunit:test(erx_ui_wire_tests, [verbose]) of ok -> 0; _ -> 1 end)', chdir: work)
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_the_three_readers_read_the_corpus_alike
    in_erlang do |work|
      stream = File.join(work, 'stream')
      read = File.join(work, 'read')
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "erx_ui_wire_tests:corpus(\"#{stream}\", \"#{read}\", 7), halt(0)", chdir: work)
      native = read_stream([harness(work)], stream)
      assert_operator native.size, :>, 600
      assert_equal native, File.readlines(read, chomp: true).map { |line| numeric(line) }, 'the Erlang reader'
      typescript_harness do |reader|
        # In "rewrite" mode the harness also writes each record it read with
        # the TypeScript writer, and refuses the stream unless the bytes are
        # the Erlang encoder's.
        assert_equal native, read_stream([*reader, 'rewrite'], stream).map { |line| numeric(line) },
                     'the TypeScript reader and writer'
      end
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

  # Each record of the Erlang corpus with a byte changed, its body cut short or
  # a byte added, framed again, read record by record by the three readers, which
  # must refuse the same records for the same reasons and read the same
  # meaning from the rest: the readers' checks of bounds, members, statuses and
  # lengths compared on what no valid corpus reaches.
  def test_the_three_readers_agree_on_mutated_records
    in_erlang do |work|
      stream = File.join(work, 'stream')
      mutated = File.join(work, 'mutated')
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "erx_ui_wire_tests:corpus(\"#{stream}\", \"#{File.join(work, 'expected')}\", 11), halt(0)", chdir: work)
      File.binwrite(mutated, mutations(File.binread(stream), random: Random.new(11)))
      native = read_stream([harness(work), 'each'], mutated).map { |line| in_number_order(line) }
      assert_operator native.count { |line| line.start_with?('refused: ') }, :>, 500
      assert_operator native.count { |line| !line.start_with?('refused: ') }, :>, 500
      assert_equal native, read_each_in_erlang(work, mutated), 'the Erlang reader'
      typescript_harness do |reader|
        lines = read_stream([*reader, 'each'], mutated)
        assert_equal native, lines.map { |line| line.start_with?('refused: ', 'more') ? line : numeric(line) }
      end
    end
  end

  def test_erlang_reader_reads_what_the_typescript_writer_writes
    in_erlang do |work|
      typescript_harness do |writer|
        stream = File.join(work, 'stream')
        read = File.join(work, 'read')
        written = run!(*writer, 'write', stream, '7', chdir: work).lines(chomp: true)
        run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
             "erx_ui_wire_tests:read_corpus(\"#{stream}\", \"#{read}\"), halt(0)", chdir: work)
        assert_equal 600, written.size
        assert_equal written, File.readlines(read, chomp: true)
        seen = written.filter_map { |line| line.split(' ')[2] if line.start_with?('event ') }.uniq.sort
        assert_equal UI.properties.select { |prop| prop.type.form == 'event' }.map(&:name).sort, seen
      end
    end
  end

  # A valid record with one field broken, for each reason the C reader gives;
  # the TypeScript and Erlang readers refuse each for the same reason.
  def test_the_three_readers_refuse_each_broken_record_for_its_reason
    cases = refusals
    Dir.mktmpdir('erx-ui-wire-refusal') { |work| refused_alike([harness(work)], cases) }
    typescript_harness { |reader| refused_alike(reader, cases) }
    in_erlang do |work|
      stream = File.join(work, 'refusals')
      File.binwrite(stream, cases.keys.join)
      assert_equal cases.values.map { |reason| "refused: #{reason}" }, read_each_in_erlang(work, stream)
    end
  end

  private

  def refused_alike(reader, cases)
    cases.each do |bytes, reason|
      _out, error, status = Open3.capture3(*timed(reader), stdin_data: bytes, binmode: true)
      refute status.success?, "accepted a record refused for #{reason}"
      assert_equal "refused at 0: #{reason}", error.chomp
    end
  end

  # The lines erx_ui_wire_tests:read_each/2 writes for the stream at path,
  # with the names it prints mapped to numbers as the C harness prints them.
  def read_each_in_erlang(work, path)
    out = File.join(work, 'each')
    run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
         "erx_ui_wire_tests:read_each(\"#{path}\", \"#{out}\"), halt(0)", chdir: work)
    File.readlines(out, chomp: true).map { |line| line.start_with?('refused: ', 'more') ? line : numeric(line) }
  end

  # Records refused for each reason, the one refused for a bad length last,
  # since a reader reading on stops there.
  def refusals
    visible, placeholder, text = %w[visible placeholder text].map { |name| property(name).number }
    {
      record('C', 12) => 'unknown tag',
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
      record('Cv', 7, 1) => 'short record',
      [0].pack('V') => 'bad length'
    }
  end

  # Four mutants of each record of stream: one byte replaced, the body cut
  # short, a byte inserted and one byte set to 0xff, each framed with its
  # body's length.
  def mutations(stream, random:)
    bodies = []
    offset = 0
    while offset < stream.bytesize
      size = stream.byteslice(offset, 4).unpack1('V')
      bodies << stream.byteslice(offset + 4, size)
      offset += 4 + size
    end
    bodies.flat_map do |body|
      at = random.rand(body.bytesize)
      [body.dup.tap { |copy| copy.setbyte(at, random.rand(256)) }, body.byteslice(0, [at, 1].max),
       body.dup.insert(at, random.rand(256).chr), body.dup.tap { |copy| copy.setbyte(at, 0xff) }]
    end.map { |body| [body.bytesize].pack('V') + body }.join
  end

  def timed(command) = ['gtimeout', '-k', '10', '300', *command]

  # The lines a reader's command prints for the stream at path, which it must read whole.
  def read_stream(reader, path)
    read, error, status = Open3.capture3(*timed(reader), stdin_data: File.binread(path), binmode: true)
    assert status.success?, "#{reader.last} refused a record the Erlang encoder wrote: #{error}"
    read.lines(chomp: true)
  end

  # The command of web/test/ui_wire_harness.ts, from the staged web tree.
  def typescript_harness
    Erx::WebStage.with(root: ROOT) { |stage| yield [*Erx::WebStage::NODE, File.join(stage, 'test/ui_wire_harness.ts')] }
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
      ErlangBuild.compile(work, applications: %w[erx erx_win], tests: TESTS)
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

  # A line of the C harness with an insert's or a set's properties in number
  # order, as numeric/1 puts them: a mutant may list them in any order, and
  # the Erlang reader reads them into a map.
  def in_number_order(line)
    tokens = line.split(' ')
    first, last = { 'insert' => [5, tokens.size], 'set' => [2, tokens.index('/')] }.fetch(tokens.first) { return line }
    [*tokens[0...first], *tokens[first...last].sort_by { |token| token.to_i }, *tokens[last..]].join(' ')
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
