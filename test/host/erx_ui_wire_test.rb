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
# source, and the two must agree line for line.
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
      reader = File.join(work, 'reader')
      run!(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-I', File.join(GENERATED, 'include'),
           HARNESS, File.join(GENERATED, Erx::ABI::UIWireEmitter::C_SOURCE_PATH), '-o', reader, chdir: work)
      read, status = Open3.capture2(reader, stdin_data: File.binread(stream), binmode: true)
      assert status.success?, 'the C reader refused a record the Erlang encoder wrote'
      lines = File.readlines(expected, chomp: true)
      assert_operator lines.size, :>, 600
      lines.zip(read.lines(chomp: true)).each { |want, got| assert_equal numeric(want), got }
      assert_equal lines.size, read.lines.size
    end
  end

  private

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
