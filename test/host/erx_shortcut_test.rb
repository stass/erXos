# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs erXos's shell shortcuts on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies): test/erlang/erx_shortcut_tests.erl, the
# collision and resolution tests, and shell sessions on erXos's shell,
# edlin_expand and shell_default, compiled from their sources into a
# directory of their own so stock's stay on the code path.
class ErxShortcutTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  STDLIB = File.join(ROOT, 'otp/lib/stdlib/src')
  OURS = %w[shell edlin_expand shell_default].freeze
  TESTS = File.join(ROOT, 'test/erlang/erx_shortcut_tests.erl')

  # Calls of OTP's names in functions defined at the prompt, and definitions of
  # names a shortcut has at another arity: erXos's shell must answer as stock's.
  STOCK_SESSION = <<~ERL
    t(P) -> trace(P, true, [send]).
    t(self()).
    mem(X) -> memory(X, x).
    mem(total).
    trace_stop(A, B) -> {A, B}.
    trace_stop(1, 2).
    source(A, B) -> {B, A}.
    s(X) -> source(X, y).
    s(x).
    i(X) -> X.
    halt().
  ERL

  def test_eunit
    in_build do |work, ours|
      compile(work, TESTS)
      output, status = erl(work, ours, '-noshell', '-pa', work,
                           '-eval', 'halt(case eunit:test(erx_shortcut_tests) of ok -> 0; _ -> 1 end).')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_prompt_definitions_call_stock_names_as_stock
    in_build do |work, ours|
      stock = transcript(erl(work, ours, stdin: STOCK_SESSION))
      erxos = transcript(erl(work, ours, '-pa', ours, stdin: STOCK_SESSION))
      assert_match(/^2> 1$/, stock)
      assert_equal stock, erxos
    end
  end

  # A shortcut's own name and arity reaches shell_default, whose erx function
  # stock's emulator lacks, and is refused as a definition, as an OTP command is.
  def test_prompt_definitions_call_shortcuts
    in_build do |work, ours|
      erxos, = erl(work, ours, '-pa', ours, stdin: <<~ERL)
        s(X) -> trace(X).
        s(x).
        trace(X) -> X.
        halt().
      ERL
      assert_match(/^2> \*\* exception error: undefined function erx:trace\/1$/, erxos)
      assert_match(/^3> \* 1:10: syntax error before: '->'$/, erxos)
    end
  end

  # Stock's shell resolves a call by its name's unquoted text, which for 'Foo'
  # scans to no atom, so its server dies of a case_clause; erXos's resolves
  # the atom.
  def test_prompt_definitions_call_quoted_names
    in_build do |work, ours|
      erxos, = erl(work, ours, '-pa', ours, stdin: <<~ERL)
        g(X) -> 'Foo'(X).
        g(1).
        halt().
      ERL
      assert_match(/^2> \*\* exception error: undefined function shell_default:'Foo'\/1$/, erxos)
    end
  end

  private

  def in_build
    Dir.mktmpdir('erx-shortcut-test') do |work|
      ours = File.join(work, 'erxos')
      Dir.mkdir(ours)
      OURS.each { |module_name| compile(ours, File.join(STDLIB, "#{module_name}.erl")) }
      yield work, ours
    end
  end

  def erl(work, ours, *args, stdin: '')
    Open3.capture2e({ 'ERX_STDLIB_EBIN' => ours },
                    'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-nostick', *args,
                    chdir: work, stdin_data: stdin)
  end

  # The session's output without the last prompt, which halt/0 may end the
  # emulator before or after printing.
  def transcript((output, _status)) = output.sub(/^\d+> \z/, '')

  def compile(directory, source)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', directory, source, stdin_data: '')
    assert status.success?, output
  end
end
