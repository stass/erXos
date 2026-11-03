# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/json_input'
require_relative '../../tools/generated/terminal_tables'

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

  def runtime_command(program, arguments, home: @directory)
    ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', "HOME=#{home}",
     'LANG=C', 'TERM=erx-no-terminfo-profile', program, *arguments]
  end

  def erlang(expression, home: @directory)
    command = runtime_command(@erl, ['-noshell', '-noinput', '-boot', 'no_dot_erlang',
                                     '-pa', @directory, '-eval', expression], home: home)
    record = @runner.run(command, name: 'terminal-oracle', deadline: 30, chdir: @directory)
    Erx::JsonInput.parse(File.binread(record.fetch('log')))
  end

  def test_renderer_oracle_does_not_execute_operator_startup
    home = File.join(@directory, 'operator-home')
    Dir.mkdir(home)
    marker = File.join(@directory, 'startup-executed')
    File.write(File.join(home, '.erlang'), "file:write_file(#{JSON.generate(marker)}, <<\"startup\">>).\n")
    assert_equal({ 'ok' => true }, erlang('io:put_chars(json:encode(#{<<"ok">> => true})), halt().',
                                         home: home))
    refute File.exist?(marker), 'renderer oracle executed operator startup'
  end

  def test_generated_c_byte_class_exhaustively
    program = File.join(@directory, 'ascii-probe')
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                 '-fsanitize=address,undefined', '-I', File.join(ROOT, 'include'),
                 File.join(ROOT, 'test/fixtures/terminal_ascii_probe.c'), '-o', program],
                name: 'compile-terminal-ascii', deadline: 60)
    result = @runner.run([program], name: 'terminal-ascii', deadline: 30)
    assert_equal 0, result.fetch('exit_status')
  end

  def test_erlang_and_ruby_tables_have_identical_normalized_values
    @runner.run(runtime_command(@erlc, ['-Werror', '-o', @directory,
                                       File.join(ROOT, 'erlang/apps/erx/src/erx_text_tables.erl')]),
                name: 'compile-terminal-erlang', deadline: 30, chdir: @directory)
    value = erlang('Ranges = [[A,B] || {A,B} <- tuple_to_list(erx_text_tables:unicode_unsafe_ranges())], ' \
                    'io:put_chars(json:encode(#{<<"ranges">> => Ranges, <<"catalog">> => erx_text_tables:catalog()})), halt().')
    assert_equal Erx::Generated::TerminalTables::UNICODE_UNSAFE_RANGES, value.fetch('ranges')
    assert_equal Erx::Generated::TerminalTables::CATALOG, value.fetch('catalog')
  end

  def test_renderer_catalog_agrees_with_real_pinned_fallback
    value = erlang('M = #{<<"cursor_up">> => io_ansi:cursor_up(), <<"newline">> => io_ansi:cursor_down(), ' \
                    '<<"beep">> => element(1,prim_tty:handle_request(undefined,beep)), ' \
                    '<<"backspace">> => io_ansi:cursor_backward(), <<"cursor_forward">> => io_ansi:cursor_forward(), ' \
                    '<<"erase_after_cursor">> => io_ansi:erase_display(), <<"tab_forward">> => io_ansi:tab(), ' \
                    '<<"styled">> => io_ansi:format([cyan_background,light_white,bold,"x"],[],[{enabled,true},{color,true},{reset,true}])}, ' \
                    'io:put_chars(json:encode(M)), halt().')
    catalog = Erx::Generated::TerminalTables::CATALOG
    assert_renderer_agrees(catalog, value)
    changed = Marshal.load(Marshal.dump(catalog))
    changed.fetch('sequence').fetch('prim_tty/cursor_up')['final'] = 66
    assert_raises(Minitest::Assertion) { assert_renderer_agrees(changed, value) }
    changed = Marshal.load(Marshal.dump(catalog))
    changed.fetch('literal').fetch('prim_tty/beep')['bytes'] = [27, 93]
    assert_raises(Minitest::Assertion) { assert_renderer_agrees(changed, value) }
  end

  def assert_renderer_agrees(catalog, value)
    expected = catalog.fetch('literal').values.select { |row| row.fetch('profile') == 'prim_tty' }
                      .to_h { |row| [row.fetch('name'), row.fetch('bytes').pack('C*')] }
    catalog.fetch('sequence').values.select { |row| row.fetch('profile') == 'prim_tty' }.each do |row|
      expected[row.fetch('name')] = (row.fetch('introducer') + row.fetch('private') +
                                    row.fetch('intermediate') + [row.fetch('final')]).pack('C*')
    end
    value.each do |name, bytes|
      next if name == 'styled'
      assert_equal expected.fetch(name), bytes, name
    end
    styled = %w[cyan_background light_white bold].map { |name| expected.fetch(name) }.join +
             'x' + expected.fetch('reset_rendition')
    assert_equal styled, value.fetch('styled')
  end
end
