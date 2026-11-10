# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'io/console'
require 'minitest/autorun'
require 'open3'
require 'pty'
require 'tmpdir'
require 'io/wait'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/runtime'

# erx_console, its group and prim_tty's terminal-less state over erx_stdio, typed at through
# a terminal, and the same keys typed at stock OTP. Stock runs with `+Bc`, which gives
# Ctrl-C the meaning it has on erXos, whose terminal is raw: interrupt the evaluator. What
# each screen shows must match, but for the banner line. The differences stock cannot agree
# with are the last tests here, each named.
#
# `make check-runtime-hosted` builds the runtime and runs this; `make check` does not.
class RuntimeConsoleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  BUDGET_SECONDS = 60
  LEFT = "\e[D"
  RIGHT = "\e[C"
  UP = "\e[A"
  CTRL_A = "\x01"
  CTRL_C = "\x03"
  CTRL_E = "\x05"
  CTRL_G = "\x07"
  CTRL_K = "\x0b"
  BACKSPACE = "\x7f"
  LONG_ATOM = 'a' * 200

  # The Erlang shell prompt before its command count: the node name of the hosted system
  # domain, in parentheses. `with_stock` gives stock the same prompt, so the two screens
  # compare.
  NODE = 'system@erxos'
  PROMPT = "\\(#{Regexp.escape(NODE)}\\)"

  # A module that gives a stock shell the prompt erXos's has, `(NODE)N> `; an unnamed
  # stock node prints only `N> `, and a named one would start epmd.
  PROMPT_MODULE = <<~ERLANG
    -module(erx_console_test_prompt).
    -export([prompt/1]).
    prompt([{history, N}]) -> io_lib:format("(#{NODE})~w> ", [N]).
  ERLANG

  # What a terminal shows: enough of a VT100 to render what prim_tty writes, including a
  # line that fills its last column and wraps on the next character.
  class Screen
    SEQUENCE = /\A\e\[([0-9;?]*)([A-Za-z])/n

    attr_reader :raw

    def initialize(columns:)
      @columns = columns
      @lines = [[]]
      @row = 0
      @column = 0
      @raw = String.new(encoding: Encoding::BINARY)
    end

    def resize(columns:) = @columns = columns

    def <<(bytes)
      @raw << bytes
      rest = (@pending.to_s.b + bytes.b)
      @pending = nil
      until rest.empty?
        if rest.start_with?("\e")
          match = SEQUENCE.match(rest)
          if match.nil?
            @pending = rest if rest.size < 8
            rest = rest.size < 8 ? '' : rest[1..]
            next
          end
          control(match[1], match[2])
          rest = match.post_match
        else
          rest = text(rest)
        end
      end
      self
    end

    def to_s = @lines.map(&:join).join("\n")

    private

    def text(bytes)
      character = bytes[/\A(?:[\x00-\x7f]|[\xc0-\xff][\x80-\xbf]*)/n] || bytes[0]
      case character
      when "\r" then @column = 0
      when "\n" then line_feed
      when "\b" then @column = [@column - 1, 0].max
      when "\a" then nil
      else put(character.dup.force_encoding('UTF-8'))
      end
      bytes[character.bytesize..]
    end

    def put(character)
      return if !character.valid_encoding? || character.ord < 0x20

      if @column >= @columns
        @column = 0
        line_feed
      end
      line = @lines[@row]
      line.fill(' ', line.size...@column)
      line[@column] = character
      @column += 1
    end

    def line_feed
      @row += 1
      @lines << [] while @lines.size <= @row
    end

    def control(argument, final)
      count = [argument.to_i, 1].max
      case final
      when 'A' then @row = [@row - count, 0].max
      when 'B' then count.times { line_feed }
      when 'C' then @column = [@column + count, @columns - 1].min
      when 'D' then @column = [[@column, @columns - 1].min - count, 0].max
      when 'K' then @lines[@row] = @lines[@row].first(@column)
      when 'J'
        @lines[@row] = @lines[@row].first(@column)
        @lines.slice!((@row + 1)..)
      end
    end
  end

  # One running program on one terminal, with a deadline over all of it.
  class Session
    attr_reader :screen, :status

    def initialize(reader, writer, pid, columns:, budget: BUDGET_SECONDS)
      @reader = reader
      @writer = writer
      @pid = pid
      @screen = Screen.new(columns: columns)
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
    end

    def type(keys) = @writer.write(keys)

    # The program's status once it exits. An exit that hangs fails the test at the session's
    # deadline, where a blocking wait would hold the gate forever; the caller's cleanup ends it.
    def reap
      loop do
        waited = Process.waitpid2(@pid, Process::WNOHANG)
        return waited.last if waited
        raise Minitest::Assertion, "did not exit:\n#{@screen}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline

        IO.select(nil, nil, nil, 0.05)
      end
    end

    # The rendered screen as it stands, with the line the cursor is on last.
    def wait_for(pattern)
      loop do
        return if pattern.match?(@screen.to_s)

        left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Minitest::Assertion, "no #{pattern.inspect} in:\n#{@screen}" if left <= 0

        read_once(left)
      end
    end

    def resize(rows:, columns:)
      @reader.winsize = [rows, columns]
      @screen.resize(columns: columns)
    end

    def read_to_end
      loop do
        left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Minitest::Assertion, "still running:\n#{@screen}" if left <= 0

        read_once(left)
      end
    rescue EOFError, Errno::EIO
      @status = reap
    end

    private

    def read_once(seconds)
      return unless @reader.wait_readable(seconds)

      @screen << @reader.read_nonblock(4096)
    end
  end

  def setup = Erx::Runtime.check_current(root: ROOT)

  # Each step is the keys typed and what the screen then shows, ending at the next prompt.
  def dialogue
    [
      ["1+1.\r", /^2\n#{PROMPT}2> \z/],
      # Arrow keys: the 0 goes in the middle of the line.
      ["1+2#{LEFT}#{LEFT}0#{RIGHT}#{RIGHT}.\r", /^12\n#{PROMPT}3> \z/],
      # History recalls the line just edited.
      [UP, /^#{PROMPT}3> 10\+2\.\z/],
      ["\r", /^12\n#{PROMPT}4> \z/],
      # Backspace, start and end of line, and kill to the end of the line.
      ["1+1x#{BACKSPACE}.\r", /^2\n#{PROMPT}5> \z/],
      ["+1.#{CTRL_A}2#{CTRL_E}#{LEFT}#{CTRL_K}.\r", /^3\n#{PROMPT}6> \z/],
      ["is_list(erlang:processes()).\r", /^true\n#{PROMPT}7> \z/],
      ["length(erlang:processes()) > 10.\r", /^true\n#{PROMPT}8> \z/],
      ["shell:whereis() =:= undefined.\r", /^false\n#{PROMPT}9> \z/],
      ["io:columns().\r", /^\{ok,80\}\n#{PROMPT}10> \z/],
      ["io:rows().\r", /^\{ok,24\}\n#{PROMPT}11> \z/],
      # A typed line that wraps across three rows, and an edit on its first row.
      ["length(atom_to_list('#{LONG_ATOM}')).\r", /^200\n#{PROMPT}12> \z/],
      ["length(atom_to_list('#{LONG_ATOM}#{"\x02" * 5}b#{CTRL_E}')).\r", /^201\n#{PROMPT}13> \z/],
      # Output that wraps by itself.
      ["lists:seq(1, 60).\r", /|\.\.\.\]\n#{PROMPT}14> \z/],
      ["io:put_chars(lists:duplicate(100, $x) ++ \"\\n\").\r", /^ok\n#{PROMPT}15> \z/],
      # Caret notation for control characters, as stock's io:put_chars shows at a shell. Stock
      # sets bit 040 of the character where a caret's letter has bit 0100, so \001 shows as
      # ^!, an upstream quirk pinned here by the comparison.
      ["io:put_chars(\"a\\001b\\n\").\r", /a\^!b\nok\n#{PROMPT}16> \z/],
      ["io:put_chars(\"del\\dend\\n\").\r", /del\^\?end\nok\n#{PROMPT}17> \z/],
      ["io:format(\"~s~n\", [[27, $[, $3, $1, $m, $r, 27, $[, $0, $m]]).\r", /^ok\n#{PROMPT}18> \z/],
      # Characters past ASCII, one of them two columns wide.
      ["io:put_chars(\"h\\x{e9}llo\\n\").\r", /h\u00e9llo\nok\n#{PROMPT}19> \z/],
      ["length(\"\u65e5\u672c\").\r", /^2\n#{PROMPT}20> \z/],
      # Completion.
      ["lists:rev\t", /lists:reverse\(\z/],
      ["\"ab\").\r", /^"ba"\n#{PROMPT}21> \z/],
      # Ctrl-C interrupts what the shell is evaluating.
      ["io:put_chars(\"sleeping\\n\"), timer:sleep(infinity).\r", /^sleeping\n\z/],
      [CTRL_C, /killed\n#{PROMPT}22> \z/],
      ['abc', /#{PROMPT}22> abc\z/],
      [CTRL_C, /> \z/],
      ["erlang:system_info(wordsize).\r", /^8\n#{PROMPT}\d+> \z/]
    ]
  end

  def spawn_session(environment, program, *arguments, chdir:)
    PTY.spawn(environment, program, *arguments, chdir: chdir) do |reader, writer, pid|
      reader.winsize = [24, 80]
      session = Session.new(reader, writer, pid, columns: 80)
      yield session
    ensure
      end_if_running(pid)
    end
  end

  def end_if_running(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # The console's first shell: the command shell, at its prompt. The boot's log records
  # may land between its banner and its prompt.
  CONSOLE_RC = /^rc: the command shell; erl starts the Erlang shell\n(?:.*\n)*% \z/

  # A session at the console's command shell.
  def with_command_shell
    Dir.mktmpdir('erx-console') do |home|
      environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge('TZ' => 'UTC')
      spawn_session(environment, OUTPUT.beam, OUTPUT.archive, chdir: home) do |session|
        session.wait_for(CONSOLE_RC)
        yield session
      end
    end
  end

  # A session at an Erlang shell that `erl` started from the console's command shell.
  def with_erxos
    with_command_shell do |session|
      session.type("erl\r")
      session.wait_for(/^#{PROMPT}1> \z/)
      yield session
    end
  end

  # Compiles the prompt module into `directory`, which stock's `-pa` then names.
  def compile_prompt_module(erlc, directory)
    source = File.join(directory, 'erx_console_test_prompt.erl')
    File.write(source, PROMPT_MODULE)
    log, status = Open3.capture2e(erlc, '-o', directory, source)
    raise "erlc failed: #{log}" unless status.success?

    directory
  end

  # A session at stock OTP's Erlang shell, prompting as erXos's does.
  def with_stock
    Erx::Oracle.new(root: ROOT).with_runtime('emu') do |tools|
      Dir.mktmpdir('erx-console-stock') do |home|
        environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge(
          'HOME' => home, 'TERM' => 'xterm', 'LC_ALL' => 'en_US.UTF-8', 'TZ' => 'UTC'
        )
        prompts = compile_prompt_module(tools.fetch('erlc'), home)
        spawn_session(environment, tools.fetch('erl'), '+Bc', '-pa', prompts,
                      '-stdlib', 'shell_prompt_func', '{erx_console_test_prompt,prompt}',
                      chdir: home) do |session|
          session.wait_for(/^#{PROMPT}1> \z/)
          yield session
        end
      end
    end
  end

  def play(session, steps = dialogue)
    steps.each do |keys, pattern|
      session.type(keys)
      session.wait_for(pattern)
    end
    # From the line after the shell's banner on, since the banner names the build, and
    # erXos's names no Ctrl-G, which belongs to the console's menu.
    assert_match(%r{\AErlang/OTP 29 }, session.screen.to_s)
    session.screen.to_s[/^Eshell V[^\n]*\n(.*)/m, 1]
  end

  def keep_transcript(name, text)
    directory = ENV.fetch('ERX_TRANSCRIPT_DIR', nil)
    File.write(File.join(directory, "#{name}.txt"), text) if directory
  end

  def test_a_session_shows_what_stock_shows
    erxos = stock = nil
    with_erxos do |session|
      erxos = play(session)
      keep_transcript('erxos', session.screen.to_s)
      keep_transcript('erxos.raw', session.screen.raw)
    end
    with_stock do |session|
      stock = play(session)
      keep_transcript('stock', session.screen.to_s)
      keep_transcript('stock.raw', session.screen.raw)
    end
    assert_equal stock, erxos
  end

  # A resize reaches the console by SIGWINCH, on no path a typed line waits for, so the
  # test asks until the answer changes.
  def resized(session)
    session.resize(rows: 30, columns: 40)
    session.type("(fun Ask(0) -> gone; Ask(N) -> case io:columns() of {ok,40} -> resized; _ -> " \
                 "timer:sleep(10), Ask(N-1) end end)(1000).\r")
    session.wait_for(/^resized\n#{PROMPT}2> \z/)
    session.type("io:rows().\r")
    session.wait_for(/^\{ok,30\}\n#{PROMPT}3> \z/)
    session.type("length(atom_to_list('#{'a' * 100}')).\r")
    session.wait_for(/^100\n#{PROMPT}4> \z/)
    session.screen.to_s.lines.last(5).join
  end

  def test_a_window_size_change_moves_the_wrap_as_on_stock
    erxos = stock = nil
    with_erxos { |session| erxos = resized(session) }
    with_stock { |session| stock = resized(session) }
    assert_equal stock, erxos
    assert_includes erxos, "#{'a' * 25}\n"
  end

  def test_the_shell_stands_on_erx_console_and_no_nif_of_prim_tty
    with_erxos do |session|
      {
        'is_pid(whereis(erx_console)).' => /^true\n/,
        'whereis(user_drv).' => /^undefined\n/,
        'is_pid(whereis(user)) andalso whereis(user) =/= group_leader().' => /^true\n/,
        'erlang:ports().' => /^\[\]\n/,
        'catch prim_tty:load().' => /case_clause/,
        'prim_tty:isatty(stdin).' => /^false\n/,
        'catch prim_tty:tty_create(stdout).' => /undef/,
        'prim_tty:tigetstr("sgr0").' => /^false\n/,
        'os:getenv("HOME").' => /^false\n/,
        'os:getenv("TERM").' => /^false\n/,
        'os:getenv("PROGNAME").' => /^false\n/,
        'filename:basedir(user_cache, "x").' => %r{^"/\.cache/x"\n}
      }.each_with_index do |(line, pattern), index|
        shown = session.screen.to_s.size
        session.type("#{line}\r")
        session.wait_for(/^#{PROMPT}#{index + 2}> \z/)
        assert_match pattern, session.screen.to_s[shown..], line
      end
    end
  end

  # The command shell, started from the Erlang shell, takes the console until it ends: a
  # variable, a loop, history, Ctrl-C of an edited line and of a running line, a line
  # continued on the next, a syntax error, rubbing out, and exit back to the Erlang shell,
  # whose own history the command shell's lines did not join.
  RC_SESSION = [
    ["erx_shell:start().\r", /^rc: the command shell; exit ends it\n% \z/],
    ["x=(a b c)\r", /^% x=\(a b c\)\n% \z/],
    ["for(i in $x) echo $i\r", /^a\nb\nc\n% \z/],
    [UP, /^% for\(i in \$x\) echo \$i\z/],
    [CTRL_C, /^% for\(i in \$x\) echo \$i\n% \z/],
    ["{\r", /^% \{\n\z/],
    ["echo con tinued}\r", /^echo con tinued\}\ncon tinued\n% \z/],
    ["echo a)\r", /^rc: syntax error at line 1, column 7: unexpected '\)'\n% \z/],
    ["echo $status\r", /^unexpected '\)'\n% \z/],
    ["while(true) true\r", /^% while\(true\) true\n\z/],
    [CTRL_C, /^\^C\n% \z/],
    ["echo xy#{BACKSPACE}z\r", /^xz\n% \z/],
    ["exit\r", /^% exit\nok\n#{PROMPT}2> \z/],
    [UP, /^#{PROMPT}2> erx_shell:start\(\)\.\z/],
    ["\r", /\n% \z/],
    ["exit\r", /^% exit\nok\n#{PROMPT}3> \z/]
  ].freeze

  RC_TRANSCRIPT = <<~SCREEN.chomp
    1> erx_shell:start().
    rc: the command shell; exit ends it
    % x=(a b c)
    % for(i in $x) echo $i
    a
    b
    c
    % for(i in $x) echo $i
    % {
    echo con tinued}
    con tinued
    % echo a)
    rc: syntax error at line 1, column 7: unexpected ')'
    % echo $status
    unexpected ')'
    % while(true) true
    ^C
    % echo xz
    xz
    % exit
    ok
    2> erx_shell:start().
    rc: the command shell; exit ends it
    % exit
    ok
    3>
  SCREEN

  # A screen's text with the node name of each prompt line removed.
  def without_node(text) = text.gsub(/^#{PROMPT}(?=\d+> )/, '')

  def test_the_command_shell_takes_the_console_and_gives_it_back
    with_erxos do |session|
      RC_SESSION.each do |keys, pattern|
        session.type(keys)
        session.wait_for(pattern)
      end
      keep_transcript('rc', session.screen.to_s)
      assert_equal RC_TRANSCRIPT, without_node(session.screen.to_s[/^#{PROMPT}1> .*/m]).rstrip
    end
  end

  # The command shell runs Erlang commands: a pipeline, a name no command has, and a
  # file in the runtime's own /tmp that a redirection writes and cat reads back.
  def test_the_command_shell_runs_erlang_commands
    with_erxos do |session|
      [["erx_shell:start().\r", /^rc: the command shell; exit ends it\n% \z/],
       ["echo a b | cat\r", /^% echo a b \| cat\na b\n% \z/],
       ["nosuch\r", /^nosuch: not found\n% \z/],
       ["echo hello >/tmp/x; cat /tmp/x\r", /^% echo hello >\/tmp\/x; cat \/tmp\/x\nhello\n% \z/],
       ["exit\r", /^% exit\nok\n#{PROMPT}2> \z/]].each do |keys, pattern|
        session.type(keys)
        session.wait_for(pattern)
      end
    end
  end

  # Two shells started through erx_console:run_shell/1 whose processes wait for `stop`;
  # the outer one ends first, with a reason, and each caller prints how its shell ended
  # through `user`, which is always shown. The Erlang shell writes while a shell is above
  # it.
  NESTED_SHELLS = 'Shell = fun(R) -> spawn(fun() -> receive stop -> exit(R) end end) end, ' \
                  'Run = fun(Name, P) -> spawn(fun() -> io:format(user, "~s: ~p~n", ' \
                  '[Name, erx_console:run_shell({erlang, element, [1, {P}]})]) end) end, ' \
                  'P1 = Shell(first), P2 = Shell(normal), Run("first", P1), timer:sleep(300), ' \
                  'Run("second", P2), timer:sleep(300), io:format("hid~s~n", ["den"]), ' \
                  'P1 ! stop, timer:sleep(300), P2 ! stop, timer:sleep(300), done.'

  def test_shells_on_the_console_end_in_any_order_and_a_hidden_group_is_not_shown
    with_erxos do |session|
      session.type("#{NESTED_SHELLS}\r")
      session.wait_for(/^done\n#{PROMPT}2> \z/)
      screen = session.screen.to_s
      assert_match(/^first: \{error,first\}$/, screen)
      assert_match(/^second: ok$/, screen)
      refute_match(/^hidden$/, screen)
    end
  end

  # The input ending while a command shell started from `erl`'s Erlang shell reads ends
  # it, and then the Erlang shell below it, whose end of input ends the runtime with
  # status 0.
  def test_the_input_ending_under_the_command_shell_ends_both_shells
    Open3.popen2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                  OUTPUT.beam, OUTPUT.archive) do |input, output, waiter|
      input.write("erl\n")
      input.flush
      seen = +''
      begin
        seen << output.readpartial(4096) until seen.include?("Eshell V")
        input.write("erx_shell:start().\n")
        input.flush
        seen << output.readpartial(4096) until seen.include?("exit ends it")
      rescue EOFError
        flunk "the runtime ended before the command shell started: #{seen.inspect}"
      end
      input.write("echo under rc\n")
      input.close
      seen << output.read
      assert_equal 0, waiter.value.exitstatus, seen
      assert_match(/% under rc\r?\n/, seen)
    end
  end

  # Differences from stock, each a decision of docs/design-live.md.
  # Ctrl-G opens the console's menu, which reaches no group; Esc gives the line back to
  # the shell, which draws its line again and reads on.
  def test_ctrl_g_opens_the_menu_and_reaches_no_group
    with_erxos do |session|
      session.type("12#{CTRL_G}")
      session.wait_for(/s\* system shell\n  n  start a session\nEsc returns\. \z/)
      session.type("\e")
      session.wait_for(/#{PROMPT}1> 12\z/)
      session.type("3.\r")
      session.wait_for(/^123\n#{PROMPT}2> \z/)
    end
  end

  # standard_error's bytes reach the terminal unchanged, with no CR added to a newline.
  def test_standard_error_writes_its_bytes_unchanged
    with_erxos do |session|
      session.type("io:put_chars(standard_error, \"one\\ntwo\\n\").\r")
      session.wait_for(/ok\n#{PROMPT}2> \z/)
      assert_includes session.screen.raw, "one\ntwo\n"
    end
  end

  # With no terminal, as on stock, a shell does not edit: it reads lines, and the end of
  # input ends the runtime. What follows `erl` in the same read stays with the command
  # shell's group (TODO.md), so the Erlang shell's end of input is the next test's.
  def test_end_of_input_evaluates_what_was_read_and_halts_with_status_0
    {
      '' => [],
      "echo a\necho b\n" => [/% a\r?\n/, /% b\r?\n/]
    }.each do |input, patterns|
      output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                                        OUTPUT.beam, OUTPUT.archive, stdin_data: input)
      assert_equal 0, status.exitstatus, output
      patterns.each { |pattern| assert_match pattern, output.b }
    end
  end

  def run_on_owned_terminal(line)
    Dir.mktmpdir('erx-console') do |home|
      PTY.open do |master, slave|
        slave.winsize = [24, 80]
        pid = Process.spawn(Erx::Oracle::CLEAN_ERLANG_ENV, OUTPUT.beam, OUTPUT.archive, in: slave, out: slave, err: slave,
                                                                                         chdir: home)
        session = Session.new(master, master, pid, columns: 80)
        session.wait_for(CONSOLE_RC)
        session.type("erl\r")
        session.wait_for(/^#{PROMPT}1> \z/)
        refute slave.echo?, 'raw while the shell runs'
        session.type(line)
        yield session.reap, slave
      ensure
        end_if_running(pid)
      end
    end
  end

  def test_a_read_error_is_reported_and_ends_with_status_1
    # A directory opens as standard input and fails at its first read.
    reader, writer = IO.pipe
    pid = Process.spawn(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                        OUTPUT.beam, OUTPUT.archive, in: ROOT, out: writer, err: writer)
    writer.close
    output = reader.read
    _, status = Process.wait2(pid)
    assert_equal 1, status.exitstatus, output
    assert_match(/erx_stdio: reading standard input: /, output)
  end

  # The console's first shell: `exit` ends it and a fresh one takes its place.
  def test_exit_at_the_first_shell_starts_a_fresh_one
    with_command_shell do |session|
      session.type("exit\r")
      session.wait_for(/^% exit\nrc: the command shell; erl starts the Erlang shell\n% \z/)
      session.type("echo again\r")
      session.wait_for(/^again\n% \z/)
    end
  end

  # A crash of the first shell's process while it has the input starts a fresh one too:
  # the Erlang shell kills it once q() has handed the input back.
  KILL_FIRST_SHELL = '{dictionary, D} = process_info(erx_console:first_group(), dictionary), ' \
                     'Sh = proplists:get_value(shell, D), spawn(fun() -> timer:sleep(300), exit(Sh, kill) end), q().'

  def test_a_crash_of_the_first_shell_starts_a_fresh_one
    with_erxos do |session|
      session.type("#{KILL_FIRST_SHELL}\r")
      session.wait_for(/rc: the command shell; erl starts the Erlang shell\n% \z/)
      session.type("echo after\r")
      session.wait_for(/^after\n% \z/)
    end
  end

  # q() and exit() end the Erlang shell `erl` started, and the command shell reads on;
  # the runtime runs on.
  def test_q_and_exit_end_the_erlang_shell_and_return_to_the_command_shell
    with_erxos do |session|
      session.type("q().\r")
      session.wait_for(/^#{PROMPT}1> q\(\)\.\n% \z/)
      session.type("erl\r")
      session.wait_for(/^#{PROMPT}1> \z/)
      session.type("exit().\r")
      session.wait_for(/^#{PROMPT}1> exit\(\)\.\n% \z/)
      session.type("echo running\r")
      session.wait_for(/^running\n% \z/)
    end
  end

  # A killed Erlang shell fails `erl`, which says why, and the command shell reads on.
  def test_a_killed_erlang_shell_returns_to_the_command_shell
    with_erxos do |session|
      session.type("exit(group:whereis_shell(), kill).\r")
      session.wait_for(/killed[^\n]*\n% \z/)
      session.type("echo alive\r")
      session.wait_for(/^alive\n% \z/)
    end
  end

  def test_init_stop_ends_with_status_0
    run_on_owned_terminal("init:stop().\r") do |status, slave|
      assert_equal 0, status.exitstatus
      assert slave.echo?
    end
  end

  def test_noshell_runs_what_it_is_told_with_no_prompt
    output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                                     OUTPUT.beam, OUTPUT.archive, '-noshell', '-eval', 'io:format("hi~n"), halt().',
                                     stdin_data: '')
    assert_equal 0, status.exitstatus, output
    assert_match(/^hi\n/, output)
    refute_match(/1> /, output)
  end

  def test_halt_restores_the_terminal_with_status_0
    run_on_owned_terminal("halt().\r") do |status, slave|
      assert_equal 0, status.exitstatus
      assert slave.echo?
    end
  end

  def test_a_crash_restores_the_terminal_too
    run_on_owned_terminal("erlang:halt(\"boom\").\r") do |status, slave|
      refute_equal 0, status.exitstatus
      assert slave.echo?
    end
  end
end

# Reaping needs no runtime, so it stands outside RuntimeConsoleTest's setup.
class RuntimeConsoleReapTest < Minitest::Test
  def test_a_program_that_does_not_exit_fails_at_the_deadline
    pid = Process.spawn('sleep', '60')
    session = RuntimeConsoleTest::Session.new(nil, nil, pid, columns: 80, budget: 0.2)
    assert_raises(Minitest::Assertion) { session.reap }
  ensure
    Process.kill('KILL', pid)
    Process.wait(pid)
  end

  def test_a_program_that_exits_gives_its_status
    pid = Process.spawn('sh', '-c', 'exit 3')
    assert_equal 3, RuntimeConsoleTest::Session.new(nil, nil, pid, columns: 80).reap.exitstatus
  end
end
