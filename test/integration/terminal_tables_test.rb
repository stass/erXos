# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/json_input'
require_relative '../../tools/lib/erx/generated_terminal_tables'
require_relative '../fixtures/generated_tree'

class TerminalTablesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze

  def setup
    @directory = Dir.mktmpdir('terminal-tables-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @erl = ENV.fetch('ERX_ERL', File.join(ROOT, 'build/oracle/jit/install/bin/erl'))
    @erlc = ENV.fetch('ERX_ERLC', File.join(ROOT, 'build/oracle/jit/install/bin/erlc'))
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
  end

  def runtime_command(program, arguments)
    ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', "HOME=#{@directory}",
     'LANG=C', program, *arguments]
  end

  def erlang(expression)
    command = runtime_command(@erl, ['-noshell', '-noinput', '-boot', 'no_dot_erlang',
                                     '-pa', @directory, '-eval', expression])
    record = @runner.run(command, name: 'terminal-tables', deadline: 30, chdir: @directory)
    Erx::JsonInput.parse(File.binread(record.fetch('log')))
  end

  def test_generated_c_byte_class_exhaustively
    program = File.join(@directory, 'ascii-probe')
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                 '-fsanitize=address,undefined', *Erx::Generated.include_flags(root: ROOT),
                 '-I', File.join(ROOT, 'include'),
                 File.join(ROOT, 'test/fixtures/terminal_ascii_probe.c'), '-o', program],
                name: 'compile-terminal-ascii', deadline: 60)
    result = @runner.run([program], name: 'terminal-ascii', deadline: 30)
    assert_equal 0, result.fetch('exit_status')
  end

  def test_erlang_and_ruby_tables_have_identical_normalized_values
    @runner.run(runtime_command(@erlc, ['-Werror', '-o', @directory,
                                       File.join(ROOT, 'build/gen/erlang/apps/erx/src/erx_text_tables.erl')]),
                name: 'compile-terminal-erlang', deadline: 30, chdir: @directory)
    value = erlang('Ranges = [[A,B] || {A,B} <- tuple_to_list(erx_text_tables:unicode_unsafe_ranges())], ' \
                    'io:put_chars(json:encode(#{<<"ranges">> => Ranges, <<"catalog">> => erx_text_tables:catalog()})), halt().')
    assert_equal Erx::Generated::TerminalTables::UNICODE_UNSAFE_RANGES, value.fetch('ranges')
    assert_equal Erx::Generated::TerminalTables::CATALOG, value.fetch('catalog')
  end
end
