# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/console_ring_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges kernel/core/console_ring.c, the ring console of
# docs/design-fiasco.md, "The kernel's lines". The route machine is a
# protocol state machine, so every sequence of WALK_DEPTH calls over WALK_OPS
# runs against ConsoleRingModel, with the state compared after each call;
# the writes are chosen so that short sequences fill the ring, overrun a
# line and leave lines open on each route. Random scripts of arbitrary bytes
# follow, then hand cases for the bounds, the close's rendering and the
# root's reader, and seeded one-line mutants of the core must each fail.
class ConsoleRingTest < Minitest::Test
  M = ConsoleRingModel
  CORE = 'kernel/core/console_ring.c'
  SOURCES = [CORE, 'kernel/core/log.c', 'test/fixtures/console_ring_driver.c'].freeze
  SEED = Integer(ENV.fetch('ERX_CONSOLE_RING_SEED', '20261123'), 10)
  WIDE_LINE = "#{'y' * 398}\r\n".b
  # Each op is [driver command, the bytes it writes or nil].
  WALK_OPS = [
    ['write 6162', 'ab'],                         # opens a line
    ['write 0d0a', "\r\n"],                       # ends one
    ['write 780a', "x\n"],                        # a whole line without a carriage return
    ['write 1b5b33316d007a0d0a', "\e[31m\0z\r\n"], # a line of a colour sequence and a NUL
    ['write 4c 480', 'L' * 480],                  # two of these overrun a line
    ["write #{WIDE_LINE.unpack1('H*')} 10", WIDE_LINE * 10], # nearly fills the ring
    ['take', nil], ['close', nil], ['drain', nil]
  ].map { |command, text| [command, text&.b] }.freeze
  WALK_DEPTH = 5

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-console-ring-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported console-ring-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build_driver(File.join(@root, CORE), name: 'driver')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_every_route_meets_every_operation
    reach = { uart: [], ring: ['take'], closed: ['close'] }
    after = { write: 'write 6162', take: 'take', close: 'close' }
    expected = { uart: { write: 'uart', take: 'ring', close: 'closed' },
                 ring: { write: 'ring', take: 'ring', close: 'closed' },
                 closed: { write: 'closed', take: 'closed', close: 'closed' } }
    reach.each do |route, path|
      after.each do |operation, command|
        state = run_driver(['reset', *path, command, 'state']).last
        assert_equal expected.fetch(route).fetch(operation), state.split[1], "#{route} then #{operation}"
      end
    end
  end

  def test_every_short_sequence_agrees_with_the_model
    commands, expected = walk
    actual = run_driver(commands)
    assert_equal expected.size, actual.size
    first = expected.zip(actual).index { |want, got| want != got }
    assert_nil first, "first disagreement at output #{first}: #{first && [expected[first], actual[first]]}"
    $stdout.puts("console_ring_test: #{commands.count { |command| command.start_with?('save') }} calls walked")
  end

  def test_random_scripts_agree_with_the_model
    commands, expected = random_scripts
    assert_equal expected, run_driver(commands)
  end

  # Positions only grow, modulo 2^32: the same scripts from just before the wrap.
  def test_random_scripts_agree_across_the_position_wrap
    commands, expected = random_scripts(start: (2**32) - 600)
    assert_equal expected, run_driver(commands)
  end

  def test_a_take_hands_out_only_whole_lines_and_leaves_the_open_line
    line = "#{'a' * 300}\r\n"
    out = run_driver(['verbose 1', 'reset', 'take', "write #{hex(line * 2)}", 'write 7a', 'take', 'take', 'state'])
    assert_equal ['take 0 -', "take 0 #{hex(line)}", "take 0 #{hex(line)}", 'state ring 0 0 1 0 7a'], out.grep(/take|state/)
  end

  def test_a_line_of_exactly_the_reply_fits_and_one_byte_more_is_lost
    exact = "#{'e' * (M::LINE_MAX - 2)}\r\n"
    over = "#{'o' * (M::LINE_MAX - 1)}\r\n"
    out = run_driver(['verbose 1', 'reset', 'take', "write #{hex(exact)}", "write #{hex(over)}", 'write 6f6b0a', 'take',
                      'take'])
    assert_equal ["take 1 #{hex(exact)}", "take 0 #{hex("ok\n")}"], out.grep(/take/).drop(1)
  end

  def test_an_overlong_line_is_taken_back_and_its_rest_dropped_through_the_newline_once
    out = run_driver(['verbose 1', 'reset', 'take', 'write 6b0a', "write #{hex('L' * 300)}", "write #{hex('L' * 300)}",
                      "write #{hex("tail\r\nnext\r\n")}", 'state'])
    assert_equal "state ring 0 0 0 1 #{hex("k\nnext\r\n")}", out.last
  end

  def test_the_ring_fills_to_its_last_byte_and_not_one_past
    full = "#{'f' * (M::LINE_MAX - 2)}\r\n" * 8 + "#{'g' * (M::BYTES - (8 * M::LINE_MAX) - 2)}\r\n"
    assert_equal M::BYTES, full.bytesize
    out = run_driver(['reset', 'take', "write #{hex(full)}", 'state', 'write 7a0a', 'state'])
    assert_equal "state ring 0 0 0 0 #{M.bytes(full.b, verbose: false)}", out[-3]
    assert_equal "state ring 0 0 0 1 #{M.bytes(full.b, verbose: false)}", out[-1]
  end

  def test_a_take_drops_the_rest_of_a_line_the_uart_started
    out = run_driver(['verbose 1', 'reset', 'write 6869', 'take', 'write 74686572650d0a', 'write 6e6578740a', 'take'])
    assert_equal ['write uart', 'take 1 -', 'write ring', 'write ring', "take 0 #{hex("next\n")}"], out.drop(1)
  end

  # A panic prints with no newline ahead of it, so a line open in the ring
  # at the close must not swallow the stop's report, and the close writes
  # the open line out as the ring's last, losing nothing.
  def test_a_close_writes_the_open_line_last_and_the_report_reaches_the_uart_whole
    out = run_driver(['verbose 1', 'reset', 'take', "write #{hex("whole\r\nhal")}", 'close',
                      "write #{hex("Panic: x\r\n")}", 'state', 'drain'])
    rendered = "fiasco: whole\r\nfiasco: hal\r\n"
    assert_equal ['close 1', 'write uart', "state closed 0 0 0 0 #{hex("whole\r\nhal")}", "drain #{hex(rendered)}"],
                 out.last(4)
  end

  # After the close only its drain hands out what the ring holds.
  def test_a_take_after_the_close_hands_out_nothing
    out = run_driver(['verbose 1', 'reset', 'take', "write #{hex('L' * 500)}", "write #{hex("\nkept\r\n")}", 'close',
                      'take', 'state', 'drain'])
    rendered = "fiasco: 1 kernel lines lost\r\nfiasco: kept\r\n"
    assert_equal ['take 0 -', "state closed 0 0 0 1 #{hex("kept\r\n")}", "drain #{hex(rendered)}"], out.last(3)
  end

  def test_the_close_renders_escape_and_nul_escaped_and_skips_empty_lines
    out = run_driver(['verbose 1', 'reset', 'take', "write #{hex("\e[31mred\0\r\n\r\n\n")}", 'close', 'drain', 'drain'])
    assert_equal ["drain #{hex("fiasco: \\x1B[31mred\\x00\r\n")}", 'drain -'], out.last(2)
  end

  def test_drain_pieces_end_on_whole_tokens
    escapes = "\e" * (M::LINE_MAX - 2)
    out = run_driver(['verbose 1', 'reset', 'take', "write #{hex("#{escapes}\r\n")}", 'close', 'drain 1'])
    pieces = out.grep(/\Apiece /).map { |piece| [piece.split[1]].pack('H*') }
    assert_equal "fiasco: #{'\\x1B' * 30}", pieces.first
    assert(pieces.drop(1).all? { |piece| piece.match?(/\A(\\x1B)*(\r\n)?\z/) }, pieces.inspect)
    assert_equal "fiasco: #{'\\x1B' * escapes.size}\r\n", pieces.join
  end

  def test_the_loss_count_saturates_its_text
    assert_equal ['loss 0 kernel lines lost', "loss #{(2**64) - 1} kernel lines lost"],
                 run_driver(['loss 0', "loss #{(2**64) - 1}"])
  end

  def test_the_reader_strips_one_carriage_return_and_skips_empty_lines
    bytes = "a\r\n\r\n\nb\r\r\nc\0d\nfrag".b
    out = run_driver(['verbose 1', reply_command(bytes)])
    assert_equal ["reply 7 #{bytes.size}", *M.reply_lines(bytes).map { |line| "line #{hex(line)}" }, 'end'], out
    assert_equal ["a", "b\r", "c\0d", 'frag'], M.reply_lines(bytes)
  end

  def test_the_reader_refuses_what_the_words_cannot_hold
    full = 'r' * M::REPLY_BYTES
    cases = {
      'no header' => reply_command('', count: 1),
      'more words than a message' => reply_command('', count: 64),
      'a length one past its words' => reply_command('abc', length: 9, count: 3),
      'a length past the reply' => reply_command(full, length: M::REPLY_BYTES + 1, count: 63)
    }
    cases.each { |name, command| assert_equal ['reply refused'], run_driver([command]), name }
    assert_equal "reply 7 #{M::REPLY_BYTES}", run_driver([reply_command(full)]).first
    assert_equal 'reply 7 8', run_driver([reply_command('12345678', count: 3)]).first
  end

  def test_the_header_is_c_and_cplusplus
    path = File.join(@directory, 'header.cc')
    File.write(path, "#include \"erx/core/console_ring.h\"\nerx_console_ring_t ring;\n")
    @runner.run([compiler.sub(/clang\z/, 'clang++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                 '-I', File.join(@root, 'include'), path], name: 'compile-cplusplus', deadline: 60)
  end

  def test_core_builds_freestanding_for_the_target
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2',
                 '--target=aarch64-none-elf', '-ffreestanding', '-mgeneral-regs-only',
                 *Erx::Generated.include_flags(root: @root), '-I', File.join(@root, 'include'),
                 '-c', File.join(@root, CORE), '-o', File.join(@directory, 'console_ring.o')],
                name: 'compile-target', deadline: 60)
  end

  def test_mutants_of_the_core_are_rejected
    assert all_cases_pass?(@driver), 'the cases the mutants must fail have to pass on the core itself'
    source = File.read(File.join(@root, CORE))
    mutants = {
      'a lost line is not counted' => ["\t\tring->lost++;\n", "\t\t;\n"],
      'a line leaves the ring cut' => ["\tlength = end - ring->tail;\n",
                                       "\tlength = ring->open - ring->tail > ERX_CONSOLE_RING_REPLY_BYTES ? " \
                                       "ERX_CONSOLE_RING_REPLY_BYTES : ring->open - ring->tail;\n\tend = ring->tail + length;\n"],
      'the open line is not taken back' => ["\tring->head = ring->open;\n", "\n"],
      'the drop does not end at the newline' => ["\t\t\tring->dropping = false;\n", "\t\t\t;\n"],
      'a take keeps the rest of the uart line' => ["\t\tif (ring->uart_line_open)\n\t\t\tconsole_ring_lose(ring);\n", "\n"],
      'a close leaves the open line out' => ["too. */\n\tring->open = ring->head;\n", "too. */\n"],
      'a close counts the open line' => ["too. */\n\tring->open = ring->head;\n",
                                         "too. */\n\tring->head = ring->open;\n\t++ring->lost;\n"],
      'a line may be one byte longer' => ['segment > ERX_CONSOLE_RING_LINE_MAX - ', 'segment > 1 + ERX_CONSOLE_RING_LINE_MAX - '],
      'the ring may overfill by one' => ['segment > ERX_CONSOLE_RING_BYTES - ', 'segment > 1 + ERX_CONSOLE_RING_BYTES - '],
      # A leftover drop under closed changes no output; the state line shows it.
      'a close leaves the drop armed' => ["\tring->dropping = false;\n\tring->route = ERX_CONSOLE_ROUTE_CLOSED;\n",
                                          "\tring->route = ERX_CONSOLE_ROUTE_CLOSED;\n"],
      'a take after the close hands out lines' => ["\tif (ring->route == ERX_CONSOLE_ROUTE_CLOSED)\n\t\treturn;\n", "\n"],
      'closed is not final' => ["\tif (ring->route == ERX_CONSOLE_ROUTE_CLOSED)\n\t\treturn (false);\n", "\n"],
      'the reader keeps the carriage return' => ["\t\t\tbody--;\n", "\t\t\t;\n"],
      'the reader takes one byte past its words' => ['> (words->count - ERX_CONSOLE_RING_REPLY_HEADER) * 8)',
                                                     '> (words->count - ERX_CONSOLE_RING_REPLY_HEADER) * 8 + 1)'],
      'the drain leaves the last line unended' => [' || ring->drain_in_line) {', ') {'],
      'the drain labels a resumed line again' => ["\t\t\tring->drain_in_line = true;\n", "\t\t\t;\n"],
      'the drain keeps the carriage return' => ["== '\\r')\n\t\tend--;\n", "== '\\r')\n\t\t;\n"],
      'the drain writes no loss line' => ["\tif (ring->lost > 0) {\n", "\tif (false) {\n"],
      'the close writes empty lines' => ["\t\t\t\tring->tail = end;\t/* an empty line */\n\t\t\t\tcontinue;\n", "\n"]
    }
    mutants.each_with_index do |(name, (original, replacement)), index|
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit one place"
      path = File.join(@directory, "mutant-#{index}.c")
      File.write(path, source.sub(original) { replacement })
      driver = build_driver(path, name: "mutant-#{index}", warnings: false, sanitizers: [])
      refute all_cases_pass?(driver), "the checks accepted the mutant: #{name}"
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')
  def hex(bytes) = bytes.empty? ? '-' : bytes.b.unpack1('H*')

  def build_driver(core, name:, warnings: true, sanitizers: @sanitizer_flags)
    output = File.join(@directory, name)
    flags = warnings ? ['-Wall', '-Wextra', '-Werror', '-pedantic'] : ['-w']
    sources = [core, *SOURCES.drop(1).map { |source| File.join(@root, source) }]
    @runner.run([compiler, '-std=c17', *flags, '-O1', '-g', *sanitizers, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), *sources, '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def run_driver(commands, driver: @driver)
    output, status = capture_driver(commands, driver: driver)
    assert status.success?, "the driver failed\n#{output.lines.last(5).join}"
    output.lines(chomp: true)
  end

  def capture_driver(commands, driver:)
    script = File.join(@directory, 'commands')
    File.write(script, commands.map { |command| "#{command}\n" }.join)
    Open3.capture2e(driver, script, stdin_data: '')
  end

  # reply COUNT HEX: the lost count 7, the length, then the bytes.
  def reply_command(bytes, length: bytes.bytesize, count: 2 + ((bytes.bytesize + 7) / 8))
    words = [7, length].pack('Q<Q<') + bytes.b
    "reply #{count} #{hex(words)}"
  end

  # Applies one walk op to the model and returns the line the driver prints.
  def apply(model, (command, text))
    case command
    when 'take' then model.take(verbose: false)
    when 'close' then model.close
    when 'drain' then model.drain(verbose: false)
    else model.write(text)
    end
  end

  # Every sequence of up to WALK_DEPTH ops, depth first: the driver saves the
  # ring at each level and restores it before the next op, so each call runs
  # once.
  def walk
    commands = ['reset']
    expected = ['reset']
    visit = lambda do |model, level|
      next if level == WALK_DEPTH

      WALK_OPS.each do |op|
        child = model.dup
        commands.push("save #{level}", op.first, 'state')
        expected.push(apply(child, op), child.state(verbose: false))
        visit.call(child, level + 1)
        commands << "restore #{level}"
      end
    end
    visit.call(M.new, 0)
    [commands, expected]
  end

  # Writes of bytes the framing cares about, any length up to past a line.
  def random_scripts(start: nil)
    rng = Random.new(SEED)
    alphabet = ["a", "\n", "\r", "\0", "\e", "\x80", '\\', '~'].map(&:b)
    commands = []
    expected = []
    200.times do
      model = M.new
      commands << ['reset', start].compact.join(' ')
      expected << 'reset'
      80.times do
        op = case rng.rand(20)
             when 0 then ['take', nil]
             when 1 then ['close', nil]
             when 2 then ['drain', nil]
             else
               text = Array.new(rng.rand(rng.rand(4).zero? ? 700 : 40)) { alphabet.sample(random: rng) }.join.b
               ["write #{hex(text)}", text]
             end
        commands.push(op.first, 'state')
        expected.push(apply(model, op), model.state(verbose: false))
      end
    end
    [commands, expected]
  end

  def all_cases_pass?(driver)
    @expected_walk ||= walk
    @expected_random ||= random_scripts
    [@expected_walk, @expected_random].all? do |commands, expected|
      output, status = capture_driver(commands, driver: driver)
      status.success? && output.lines(chomp: true) == expected
    end && reader_cases_pass?(driver)
  end

  # The reader's cases the walk does not reach, as the driver answers them.
  def reader_cases_pass?(driver)
    full = 'r' * M::REPLY_BYTES
    commands = ['verbose 1', reply_command("a\r\n"), reply_command('abc', length: 9, count: 3),
                reply_command(full, length: M::REPLY_BYTES + 1, count: 63), reply_command('', count: 64)]
    output, status = capture_driver(commands, driver: driver)
    status.success? && output.lines(chomp: true) ==
      ['reply 7 3', "line #{hex('a')}", 'end', 'reply refused', 'reply refused', 'reply refused']
  end
end
