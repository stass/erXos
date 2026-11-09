# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/log_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges kernel/core/log.c against LogModel: all 256 byte classes, the text an
# attacker would send to a terminal, cuts at every capacity around a token,
# the ring's wrap and a reader losing records, the per-space limit, malformed
# lengths and windows. Random scripts run the same operations through both,
# and seeded one-line mutants of the core must each fail. Then
# liberx/backend/hosted/log.c runs as a program would use it.
class LogTest < Minitest::Test
  M = LogModel
  SEED = Integer(ENV.fetch('ERX_LOG_SEED', '20261103'), 10)
  CORE = 'kernel/core/log.c'
  HOSTED = 'liberx/backend/hosted/log.c'
  HOSTED_CORES = %w[kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c
                    build/gen/kernel/generated/abi_decode.c build/gen/kernel/generated/abi_run.c].freeze
  FORGERIES = {
    'newline and a forged kernel line' => "ok\nerx: panic: forged\r\n",
    'csi that clears the screen' => "\e[2J\e[H",
    'osc that sets a title or a clipboard' => "\e]0;own\a\e]52;c;aGk=\e\\",
    'eight-bit csi' => "\x9b31m\x9d0;t\x9c".b,
    'bidirectional override in UTF-8' => "abc\xE2\x80\xAEevil\xE2\x80\xAC".b,
    'invisible format characters' => "a\xE2\x80\x8Bb\xE2\x81\xA0c\xEF\xBB\xBF".b,
    'invalid UTF-8' => "\xC0\x80\xFF\xFE\xED\xA0\x80".b,
    'nul, delete and bell' => "\0\x7f\a".b,
    'tab that moves the cursor into a forged column' => "ok\t\t\tkernel: panic"
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-log-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported log-test sanitizer' unless (sanitizers - %w[address undefined thread]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build_driver(File.join(@root, CORE), name: 'log')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_every_byte_class_matches_the_terminal_rule
    (0..255).each do |byte|
      output = run_driver(["escape #{hex(byte.chr)} 16"]).first
      expected = M.safe?(byte) ? byte.chr : format('\\x%02X', byte)
      assert_equal "escape 1 #{expected.bytesize} #{hex(expected)}", output, "byte #{byte}"
    end
  end

  # Written out rather than through the model: a tab moves the cursor, so it
  # is a token like any other control. A backslash is printable and stays
  # itself: the form is for reading, and a line that shows \x1B may have held
  # either, which no one can use to reach the terminal.
  def test_a_tab_is_a_token_and_a_backslash_is_itself
    assert_equal ["escape 1 4 #{hex('\\x09')}"], run_driver(["escape #{hex("\t")} 16"])
    assert_equal ["escape 1 1 #{hex('\\')}"], run_driver(["escape #{hex('\\')} 16"])
  end

  def test_no_forgery_reaches_the_line
    FORGERIES.each do |name, bytes|
      text = M.escape_whole(bytes.b)
      refute_match(/[^ -~]/, text, name)
      refute_includes text, "\n", name
      assert_equal ["escape #{bytes.bytesize} #{text.bytesize} #{hex(text)}"],
                   run_driver(["escape #{hex(bytes)} 4096"]), name
      # A forged line stays on the line of the space that wrote it.
      lines = read_lines(["debug 7 1 #{bytes.bytesize} #{hex(bytes)}"])
      assert_equal ["#0 0.000000 debug space 7: #{text}\n"], lines, name
    end
  end

  # At every room up to and past the whole form, the output is the longest run
  # of whole tokens that fits: a \xNN is never cut.
  def test_escape_never_cuts_a_token
    input = "a\e\n\tb\xFFc".b
    (0..M.escape_whole(input).bytesize + 2).each do |capacity|
      consumed, output = M.escape(input, capacity)
      assert_equal ["escape #{consumed} #{output.bytesize} #{hex(output)}"],
                   run_driver(["escape #{hex(input)} #{capacity}"]), "capacity #{capacity}"
    end
    assert_equal ['escape 0 0 -'], run_driver(['escape - 0'])
  end

  def test_a_long_trusted_line_is_truncated_on_a_token_and_flagged
    # A token straddling the end of the record's text, at every offset of it.
    (0..4).each do |shift|
      string = ('a' * (M::TEXT_MAX - 2 - shift)) + ("\e" * 8)
      commands = ["format #{M::LEVEL_INFO} 5 #{hex(string)}", "read 0 #{M::HEADER + M::TEXT_MAX}"]
      record = read_records(commands).fetch(0)
      consumed, text = M.escape("s=#{string}".b, M::TEXT_MAX)
      assert_operator consumed, :<, string.bytesize + 2
      assert_equal M::TRUNCATED, record.flags
      assert_equal text, record.text, "shift #{shift}"
      assert_match(/ \[truncated\]\n\z/, record.line)
    end
  end

  # A record's end at every offset around format text, a negative number, a
  # hex number, a token and the shorter text after it: the text is always the
  # longest run of whole forms that fits, so nothing slips in behind a cut.
  def test_a_cut_at_any_point_leaves_a_prefix_of_the_whole_line
    (M::TEXT_MAX - 24..M::TEXT_MAX + 1).each do |pad|
      whole = "#{'p' * pad}-12345abc\ntail\nend"
      record = read_records(["cut conversions #{pad}", 'read 0 4096']).fetch(0)
      consumed, text = M.escape(whole, M::TEXT_MAX)
      assert_equal text, record.text, "pad #{pad}"
      assert_equal consumed < whole.bytesize ? M::TRUNCATED : 0, record.flags, "pad #{pad}"

      whole = ('p' * pad) + M::BAD_FORMAT
      record = read_records(["cut bad #{pad}", 'read 0 4096']).fetch(0)
      assert_equal M.escape(whole, M::TEXT_MAX).last, record.text, "pad #{pad}"
      assert_equal M::TRUNCATED, record.flags, "pad #{pad}"
    end
  end

  def test_a_full_debug_line_of_control_bytes_is_not_truncated
    bytes = "\e" * M::UTCB_BYTES
    record = read_records(["debug #{2**64 - 1} 0 #{M::UTCB_BYTES} #{hex(bytes)}", 'read 0 4096']).fetch(0)
    assert_equal 0, record.flags
    assert_equal "space #{2**64 - 1}: #{'\\x1B' * M::UTCB_BYTES}", record.text
  end

  def test_the_call_reads_exactly_len_bytes_of_the_utcb
    [0, 1, 7, 8, 9, 503, 504].each do |length|
      bytes = Array.new(M::UTCB_BYTES) { |index| 0x20 + index % 90 }.pack('C*')
      record = read_records(["debug 3 0 #{length} #{hex(bytes)}", 'read 0 4096']).fetch(0)
      assert_equal "space 3: #{M.escape_whole(bytes.byteslice(0, length))}", record.text
    end
  end

  def test_malformed_lengths_are_refused_and_change_nothing
    [505, 512, 2**31, 2**32 - 1].each do |length|
      assert_equal ['debug -1', 'state 0 0 0 0', 'read 0 0 0 0 0', 'end 0'],
                   run_driver(["debug 1 0 #{length} -", 'state', 'read 0 4096'])
    end
  end

  def test_a_bad_level_is_refused_and_changes_nothing
    [0, 5, 2**32 - 1].each do |level|
      assert_equal ['format -1', 'state 0 0 0 0'], run_driver(["format #{level} 0 41", 'state'])
    end
  end

  def test_format_conversions_and_the_format_itself_are_escaped
    records = read_records(['numbers 1', 'read 0 4096'])
    assert_equal '-2147483648 7 4294967295 abc -9223372036854775808 18446744073709551615 def -1 ' \
                 '18446744073709551615 ffffffffffffffff 18446744073709551615 12 \\x0A abc short%', records.fetch(0).text
    # A string argument cannot start a line, and %s stops at its terminator.
    string = "x\ny\e[2J\0hidden"
    assert_equal "s=x\\x0Ay\\x1B[2J", read_records(["format 3 0 #{hex(string)}", 'read 0 4096']).fetch(0).text
  end

  def test_conversions_the_core_does_not_understand_end_the_text
    { 'float' => 'a <bad format>', 'store' => 'a <bad format>', 'end' => 'a <bad format>',
      'negative' => 'a <bad format>', 'precise-number' => 'a <bad format>', 'wide-string' => 'a <bad format>' }
      .each do |name, text|
      record = read_records(["oddity #{name}", 'read 0 4096']).fetch(0)
      assert_equal text, record.text, name
      assert_equal M::TRUNCATED, record.flags, name
    end
    assert_equal 'a (null) b', read_records(['oddity null', 'read 0 4096']).fetch(0).text
  end

  # The ring's end, crossed by header, text and padding: every starting
  # phase, against the plain list the model keeps.
  def test_records_wrap_and_the_oldest_give_way
    (1..40).each do |text_length|
      model = M.new
      commands = []
      time = 0
      (0...(2 * M::RING / M.record_bytes(text_length + 2))).each do
        time += 1
        commands << "format #{M::LEVEL_INFO} #{time} #{hex('z' * text_length)}"
        model.format_string(M::LEVEL_INFO, time, 'z' * text_length)
      end
      commands << 'state' << 'read 0 131072'
      output = run_driver(commands)
      assert_equal "state #{model.state.join(' ')}", output[commands.size - 2]
      assert_equal predicted_read(model, 0, 131_072), output.drop(commands.size - 1)
      assert_operator model.read(0, 131_072).first[2], :>, 0, 'the second pass must overwrite records'
    end
  end

  # A record reported lost once is not reported again, and nothing partial
  # is shown, at every cursor around the ring's tail.
  def test_a_reader_behind_the_ring_is_told_what_it_lost
    model = M.new
    commands = []
    600.times do |time|
      text = 'y' * (100 + time % 90)
      commands << "format 4 #{time} #{hex(text)}"
      model.format_string(4, time, text)
    end
    oldest = model.state[1]
    assert_operator oldest, :>, 5
    [0, 1, oldest - 1, oldest, oldest + 1, model.next_seq - 1, model.next_seq].each do |cursor|
      [M::HEADER + M::TEXT_MAX, 2200, 3000, 131_072].each do |window|
        output = run_driver(commands + ["read #{cursor} #{window}"]).drop(600)
        assert_equal predicted_read(model, cursor, window), output, "cursor #{cursor} window #{window}"
      end
    end
  end

  def test_a_cursor_past_the_newest_and_a_short_window_are_refused
    commands = ['format 3 0 61', 'read 2 4096', "read 0 #{M::HEADER + M::TEXT_MAX - 1}", 'read 0 0']
    assert_equal ['format 0', 'read -1 2 0 0 0', 'end 0', "read -1 0 0 0 0", 'end 0', 'read -1 0 0 0 0', 'end 0'],
                 run_driver(commands)
  end

  def test_sequence_exhaustion_is_refused_and_changes_nothing
    last = M::SEQ_LAST
    commands = ["cursor #{last - 1}", 'format 3 1 61', 'debug 1 2 1 62', 'format 3 3 63', 'state', "read #{last - 1} 4096"]
    output = run_driver(commands)
    assert_equal 'format 0', output[0]
    assert_equal 'debug -7', output[1]
    assert_equal 'format -7', output[2]
    assert_equal "state #{last} #{last - 1} #{M.record_bytes(3)} 0", output[3]
    assert_equal "read 0 #{last} 0 #{M.record_bytes(3)} 1", output[4]
  end

  # The rate's decision alone, at the window's edges.
  def test_the_rate_decision_agrees_with_the_model
    edges = [0, 1, M::NS_PER_S - 1, M::NS_PER_S, M::NS_PER_S + 1, 3 * M::NS_PER_S, 2**64 - 1]
    costs = [0, 1, M::RATE - 1, M::RATE, M::RATE + 1]
    edges.product(costs, edges, costs).each do |first, first_cost, second, second_cost|
      state = M::Rate.new(0, 0, 0)
      expected = [[first, first_cost], [second, second_cost], [first, first_cost]].map do |now, cost|
        admit, state = M.rate_step(state, now, cost)
        "rate #{admit ? 1 : 0} #{state.start} #{state.bytes} #{state.dropped}"
      end
      commands = ["rate #{first} #{first_cost}", "rate #{second} #{second_cost}", "rate #{first} #{first_cost}"]
      assert_equal expected, run_driver(commands)
    end
  end

  def test_a_flooding_space_is_held_to_its_rate_and_its_losses_are_counted
    commands = []
    model = M.new
    60.times do |index|
      commands << "debug 9 #{index} #{M::UTCB_BYTES} #{hex("\e" * M::UTCB_BYTES)}"
      model.debug(9, index, M::UTCB_BYTES, "\e" * M::UTCB_BYTES)
    end
    # Empty lines take up room too: a flood of them is not free.
    600.times do |index|
      commands << "debug 9 #{100 + index} 0 -"
      model.debug(9, 100 + index, 0, '')
    end
    commands << "debug 9 #{M::NS_PER_S} 2 6869"
    model.debug(9, M::NS_PER_S, 2, 'hi')
    commands << 'state' << 'read 0 131072'
    output = run_driver(commands)
    assert_equal Array.new(661) { 'debug 0' }, output.first(661)
    assert_equal "state #{model.state.join(' ')}", output[661]
    admitted = model.records.first(model.records.size - 1).sum(&:bytes)
    assert_operator admitted, :<=, M::RATE
    assert_operator admitted, :>, M::RATE - M.record_bytes(M::TEXT_MAX)
    # Every line is either kept or counted, and each count is reported once,
    # by the next line kept.
    shown = parse_records(output.drop(662))
    reported = shown.sum { |record| record.text[/\Aspace 9 dropped (\d+): /, 1].to_i }
    assert_equal 661, shown.size + reported
    assert_operator reported, :>, 0
    assert_match(/\Aspace 9 dropped \d+: hi\z/, shown.last.text)
  end

  def test_random_scripts_agree_with_the_model
    rng = Random.new(SEED)
    $stdout.puts("log_test: random scripts from seed #{SEED} (set ERX_LOG_SEED to change it)")
    8.times do
      model = M.new
      commands = []
      expected = []
      time = 0
      900.times do
        time += rng.rand(3) == 0 ? rng.rand(2 * M::NS_PER_S) : rng.rand(1000)
        step_random(rng, model, time, commands, expected)
      end
      assert_operator model.state[3], :>, 0, 'each script must wrap the ring and drop records'
      assert_equal expected, run_driver(commands)
    end
  end

  def test_the_window_reader_refuses_every_malformed_record
    good = wire_record(seq: 4, time_ns: 9, level: 3, flags: 0, text: 'ok ok!')
    assert_equal 'end 40', run_driver(["parse #{good.unpack1('H*')}"]).last
    cases = {
      'a raw tab in the text' => wire_record(seq: 4, time_ns: 9, level: 3, flags: 0, text: "ok\tok!"),
      'short header' => good.byteslice(0, 31),
      'text past the window' => good.byteslice(0, 37),
      'padding past the window' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: 'a').byteslice(0, 33),
      'zero level' => wire_record(seq: 0, time_ns: 0, level: 0, flags: 0, text: ''),
      'unknown level' => wire_record(seq: 0, time_ns: 0, level: 5, flags: 0, text: ''),
      'unknown flag' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 2, text: ''),
      'reserved bytes' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: '', reserved: 1),
      'length beyond the limit' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: 'a' * (M::TEXT_MAX + 8)),
      'length that wraps with padding' => [0, 0, 3, 0, 0, 2**32 - 1].pack('Q<Q<L<L<L<L<'),
      'an escape byte in the text' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: "\e[2J"),
      'a newline in the text' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: "a\nb"),
      'a high byte in the text' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: "\xC2\x9B".b),
      'nonzero padding' => wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: 'a', padding: 1),
      'a good record, then a cut one' => good + good.byteslice(0, 16)
    }
    cases.each do |name, bytes|
      output = run_driver(["parse #{bytes.unpack1('H*')}"])
      assert_match(/\Acorrupt \d+\z/, output.last, name)
    end
  end

  # A view handed to the renderer directly stands for a window rewritten
  # after its check: whatever the bytes, the line stays clean.
  def test_the_renderer_escapes_again_and_never_writes_part_of_a_line
    FORGERIES.each do |name, bytes|
      record = M::Record.new(seq: 1, time_ns: 1_500_000_000, level: 2, flags: 0, text: M.escape_whole(bytes.b))
      line = M.render(record)
      assert_equal ["render #{line.bytesize} #{hex(line)}"],
                   run_driver(["render 1 1500000000 2 0 8192 #{hex(bytes)}"]), name
    end
    line = "#1 1.500000 warning abc [truncated]\n"
    assert_equal ["render #{line.bytesize} #{hex(line)}"], run_driver(["render 1 1500000000 2 1 #{line.bytesize} #{hex('abc')}"])
    assert_equal ['render 0 -'], run_driver(["render 1 1500000000 2 1 #{line.bytesize - 1} #{hex('abc')}"])
    assert_equal ['render 0 -'], run_driver(["render 1 1500000000 2 1 0 #{hex('abc')}"])
  end

  # Seeded mutants of the core; each one edit, and each must fail.
  def test_mutants_of_the_core_are_rejected
    assert all_cases_pass?(@driver), 'the sweep the mutants must fail has to pass on the core itself'
    source = File.read(File.join(@root, CORE))
    mutants = {
      'a tab passes raw' => ['if (erx_terminal_ascii_safe[byte] != 0) {', 'if (erx_terminal_ascii_safe[byte] != 0 || byte == 9) {'],
      'a record across the ring end reads shifted text' => ['log->raw_ring, length - first);', 'log->raw_ring + 1, length - first);'],
      'a record across the ring end is written shifted' => ['__builtin_memcpy(log->raw_ring, (const uint8_t *)bytes + first,', '__builtin_memcpy(log->raw_ring + 1, (const uint8_t *)bytes + first,'],
      'a token may be cut' => ['if (capacity - written < ERX_LOG_TOKEN_BYTES)', 'if (capacity == written)'],
      'the oldest does not give way' => ['log->oldest_seq++;', ''],
      'one byte less room in the ring' => ['(log->head - log->tail) < total)', '(log->head - log->tail) <= total)'],
      'a line is not charged' => ['step.next.window_bytes += cost;', ''],
      'the limit is one over' => ['step.admit = cost <= ERX_LOG_RATE_BYTES', 'step.admit = cost <= 1 + ERX_LOG_RATE_BYTES'],
      'a window never ends' => ['>= ERX_LOG_NS_PER_S)', '> ERX_LOG_NS_PER_S)'],
      'a drop is not counted' => ['step.next.dropped++;', ''],
      'a drop count is kept after it is reported' => ['step.next.dropped = 0;', ''],
      'one byte past the utcb' => ['len.raw > ERX_UTCB_BYTES_MAX)', 'len.raw > ERX_UTCB_BYTES_MAX + 1)'],
      'the lost count is off' => ['result.lost = log->oldest_seq - seq;', 'result.lost = log->oldest_seq - seq - 1;'],
      'a cursor past the newest is taken' => ['cursor > log->next_seq)', 'cursor > log->next_seq + 1)'],
      'a window may be shorter' => ['window_size < ERX_LOG_RECORD_MAX', 'window_size + 1 < ERX_LOG_RECORD_MAX'],
      'a partial record may be copied' => ['if (window_size - result.written < total)', 'if (window_size - result.written < ERX_LOG_RECORD_SIZE)'],
      'padding is not checked' => ['if (padding[index] != 0)', 'if (false)'],
      'text is not checked' => ['if (erx_terminal_ascii_safe[(uint8_t)text[index]] == 0)', 'if (false)'],
      'the last sequence number is used' => ['if (log->next_seq == UINT64_MAX)', 'if (false)'],
      'shorter text may follow a cut' => ['	text->truncated = result.consumed < length;', '	text->truncated = false;'],
      'a cut text is not flagged' => ['.flags = text->truncated ? ERX_LOG_RECORD_TRUNCATED : 0,', '.flags = 0,']
    }
    mutants.each_with_index do |(name, (original, replacement)), index|
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit one place"
      path = File.join(@directory, "mutant-#{index}.c")
      File.write(path, source.sub(original) { replacement })
      driver = build_driver(path, name: "mutant-#{index}", warnings: false)
      refute all_cases_pass?(driver), "the checks accepted the mutant: #{name}"
    end
  end

  def test_core_builds_freestanding_for_the_target
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2',
                 '--target=aarch64-none-elf', '-ffreestanding', '-mgeneral-regs-only',
                 *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-c', File.join(@root, CORE),
                 '-o', File.join(@directory, 'log.o')], name: 'compile-target', deadline: 60)
  end

  # ERX_LOG_FORMAT holds on any compiler flags, the stopgap kernel's included:
  # the check is the language's, with warnings off.
  def test_the_format_macro_compiles_a_literal_and_nothing_else
    call = ->(format) { "#include \"erx/log.h\"\nvoid f(erx_log_t *log, const char *name);\n" \
                        "void f(erx_log_t *log, const char *name) { " \
                        "(void)ERX_LOG_FORMAT(log, ERX_LOG_LEVEL_INFO, 0, #{format}, name); }\n" }
    compile = lambda do |name, source|
      path = File.join(@directory, "#{name}.c")
      File.write(path, source)
      @runner.run([compiler, '-std=c17', '-w', *Erx::Generated.include_flags(root: @root),
                   '-I', File.join(@root, 'include'), '-c', path,
                   '-o', File.join(@directory, "#{name}.o")], name: "compile-#{name}", deadline: 60)
    end
    compile.call('literal', call.call('"%s"'))
    assert_raises(Erx::CommandError) { compile.call('variable', call.call('name')) }
  end

  def test_hosted_lines_are_escaped_and_named_for_the_process
    probe = build_probe
    forged = "x\n\e[2Jerx: panic\n"
    stdout, stderr, status = run_probe(probe, "line:#{hex(forged)}", 'length:505', 'length:504', 'line:')
    assert status.success?, stderr
    assert_equal ['status 0', 'status -1', 'status 0', 'status 0'], stdout.lines(chomp: true)
    lines = stderr.lines
    assert_equal 3, lines.size, stderr
    assert_match(/\A#0 \d+\.\d{6} debug space #{status.pid}: x\\x0A\\x1B\[2Jerx: panic\\x0A\n\z/, lines[0])
    # A length of the whole UTCB shows what the thread left there, then zeros.
    assert_match(/\A#1 \d+\.\d{6} debug space #{status.pid}: x\\x0A/, lines[1])
    assert lines[1].end_with?("#{'\\x00' * (M::UTCB_BYTES - forged.bytesize)}\n"), lines[1]
    assert_match(/\A#2 \d+\.\d{6} debug space #{status.pid}: \n\z/, lines[2])
    refute_match(/[^\t\n -~]/, stderr)
  end

  # Standard error shows every record as it is written, so the console's take finds nothing
  # and a read from the start, as dmesg makes, sees the same lines standard error showed.
  def test_hosted_take_finds_nothing_and_a_read_sees_what_standard_error_showed
    probe = build_probe
    stdout, stderr, status = run_probe(probe, "line:#{hex('one')}", "line:#{hex('two')}", 'take', 'read:0', 'read:2',
                                       'read:3')
    assert status.success?, stderr
    lines = stdout.lines(chomp: true)
    assert_equal ['status 0', 'status 0', 'take 0 lost 0', 'read 0 lost 0'], lines.first(4)
    assert_equal stderr.lines(chomp: true).map { |line| "read #{line}" }, lines[4, 2]
    assert_equal ['read 0 lost 0', 'read -1 lost 0'], lines.drop(6)
  end

  # The same number of lines go in as are shown plus dropped, over a flood from
  # several threads and across a window's end; on a machine slow enough to
  # cross more windows the split moves, and the sum does not.
  def test_hosted_flood_conserves_lines
    probe = build_probe
    stdout, stderr, status = run_probe(probe, 'flood:4:25', 'sleep:1100', 'line:6869')
    assert status.success?, stderr
    assert_equal ['flood failures 0', 'status 0'], stdout.lines(chomp: true)
    lines = stderr.lines
    last = lines.pop
    refute_empty lines
    assert_operator lines.size, :<, 100, 'the flood must have overrun its rate'
    reported = (lines + [last]).sum { |line| line[/dropped (\d+):/, 1].to_i }
    assert_equal 100, lines.size + reported, stderr
    assert_match(/: hi\n\z/, last)
  end

  # The backend's one lock, under ThreadSanitizer: threads with their own
  # UTCBs write through it into one ring and one console.
  def test_hosted_lock_is_clean_under_tsan
    probe = build_probe(name: 'hosted-tsan', sanitizers: %w[-fsanitize=thread -fno-omit-frame-pointer])
    stdout, stderr, status = run_probe(probe, 'flood:4:50')
    assert status.success?, stderr
    assert_equal ['flood failures 0'], stdout.lines(chomp: true)
    refute_includes stderr, 'ThreadSanitizer'
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')
  def hex(bytes) = bytes.empty? ? '-' : bytes.b.unpack1('H*')

  def build_driver(core, name:, warnings: true)
    output = File.join(@directory, name)
    flags = warnings ? ['-Wall', '-Wextra', '-Werror', '-pedantic'] : ['-w']
    @runner.run([compiler, '-std=c17', *flags, '-O1', '-g', *@sanitizer_flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'),
                 core, File.join(@root, 'test/fixtures/log_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def build_probe(name: 'hosted', sanitizers: @sanitizer_flags)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror', '-pedantic',
                 '-O1', '-g', *sanitizers, '-pthread', *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', @root,
                 '-I', Erx::Generated.path('kernel/generated', root: @root), '-I', File.join(@root, 'kernel/core'),
                 *HOSTED_CORES.map { |source| File.join(@root, source) },
                 File.join(@root, CORE), File.join(@root, HOSTED),
                 Erx::Generated.path('liberx/backend/hosted/generated/calls.c', root: @root),
                 File.join(@root, 'test/fixtures/log_hosted_probe.c'), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def run_probe(probe, *steps) = Open3.capture3(probe, *steps, stdin_data: '')

  def run_driver(commands, driver: @driver)
    output, status = capture_driver(commands, driver: driver)
    assert status.success?, "the driver failed\n#{output}"
    output.lines(chomp: true)
  end

  def capture_driver(commands, driver:)
    script = File.join(@directory, 'commands')
    File.write(script, commands.map { |command| "#{command}\n" }.join)
    Open3.capture2e(driver, script, stdin_data: '')
  end

  ReadRecord = Data.define(:seq, :time_ns, :level, :flags, :text, :line)

  def parse_records(lines)
    lines.grep(/\Arecord /).map do |line|
      _, seq, time, level, flags, _offset, text, rendered = line.split
      ReadRecord.new(seq: seq.to_i, time_ns: time.to_i, level: level.to_i, flags: flags.to_i,
                     text: unhex(text), line: unhex(rendered))
    end
  end

  def unhex(value) = value == '-' ? '' : [value].pack('H*')

  def read_records(commands) = parse_records(run_driver(commands))

  # The rendered lines a read from the start shows after the commands.
  def read_lines(commands) = read_records(commands + ['read 0 4096']).map(&:line)

  def wire_record(seq:, time_ns:, level:, flags:, text:, reserved: 0, padding: 0)
    bytes = [seq, time_ns, level, flags, reserved, text.bytesize].pack('Q<Q<L<L<L<L<') + text.b
    bytes + ([padding] * ((8 - text.bytesize % 8) % 8)).pack('C*')
  end

  # What the driver must print for a read: its status, each whole record with
  # its text and rendered line, and where the window ended.
  def predicted_read(model, cursor, window)
    status, records = model.read(cursor, window)
    offset = 0
    ["read #{status.join(' ')}"] + records.map do |record|
      offset += record.bytes
      "record #{record.seq} #{record.time_ns} #{record.level} #{record.flags} #{offset} " \
        "#{hex(record.text)} #{hex(M.render(record))}"
    end + ["end #{offset}"]
  end

  # One random operation, recorded with what the model says it must print.
  def step_random(rng, model, time, commands, expected)
    case rng.rand(5)
    when 0, 1
      length = rng.rand(3) == 0 ? rng.rand(600) : rng.rand(40)
      bytes = rng.bytes([length, M::UTCB_BYTES].min)
      commands << "debug 5 #{time} #{length} #{hex(bytes)}"
      padded = bytes + ("\xee".b * (M::UTCB_BYTES - bytes.bytesize))
      expected << "debug #{model.debug(5, time, length, padded)}"
    when 2
      level = rng.rand(4) + 1
      string = 'k' * rng.rand(300)
      commands << "format #{level} #{time} #{hex(string)}"
      expected << "format #{model.format_string(level, time, string)}"
    when 3
      expected << "state #{model.state.join(' ')}"
      commands << 'state'
    else
      cursor = rng.rand([model.next_seq + 2, 1].max)
      window = [2144, 4096, 131_072].sample(random: rng)
      commands << "read #{cursor} #{window}"
      expected.concat(predicted_read(model, cursor, window))
    end
  end

  # What a mutant must fail: a sweep of each kind of check above, in one run.
  def all_cases_pass?(driver)
    known_answers(driver) && random_agrees?(driver)
  end

  def known_answers(driver)
    expectations = {
      ['escape 09 16'] => ["escape 1 4 #{hex('\\x09')}"],
      ['escape 1b 3'] => ['escape 0 0 -'],
      ['debug 1 0 505 -'] => ['debug -1'],
      ["cursor #{M::SEQ_LAST}", 'debug 1 2 1 62'] => ['debug -7'],
      ['format 3 0 61', 'read 2 4096'] => ['format 0', 'read -1 2 0 0 0', 'end 0'],
      ['format 3 0 61', 'read 0 2143'] => ['format 0', 'read -1 0 0 0 0', 'end 0'],
      ['rate 0 16385'] => ['rate 0 0 0 1'],
      ['rate 0 16384', 'rate 1000000000 1'] => ['rate 1 0 16384 0', 'rate 1 1000000000 1 0'],
      ['rate 0 16385', 'rate 0 1'] => ['rate 0 0 0 1', 'rate 1 0 1 0'],
      ["parse #{hex(wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: 'a', padding: 1))}"] => ['corrupt 0'],
      ["parse #{hex(wire_record(seq: 0, time_ns: 0, level: 3, flags: 0, text: "\e"))}"] => ['corrupt 0'],
      ["cut conversions #{M::TEXT_MAX}", 'state'] => ['cut 0', "state 1 0 #{M.record_bytes(M::TEXT_MAX)} 0"],
      ["cut conversions #{M::TEXT_MAX - 19}", 'read 0 4096'] => known_cut_read(M::TEXT_MAX - 19)
    }
    expectations.all? do |commands, expected|
      output, status = capture_driver(commands, driver: driver)
      status.success? && output.lines(chomp: true) == expected
    end
  end

  # A cut line's read, predicted from the text the record's end leaves.
  def known_cut_read(pad)
    whole = "#{'p' * pad}-12345abc\ntail\nend"
    consumed, text = M.escape(whole, M::TEXT_MAX)
    record = M::Record.new(seq: 0, time_ns: 0, level: M::LEVEL_INFO, flags: consumed < whole.bytesize ? M::TRUNCATED : 0,
                           text: text)
    ['cut 0', "read 0 1 0 #{record.bytes} 1",
     "record 0 0 #{M::LEVEL_INFO} #{record.flags} #{record.bytes} #{hex(text)} #{hex(M.render(record))}",
     "end #{record.bytes}"]
  end

  def random_agrees?(driver)
    rng = Random.new(SEED)
    2.times.all? do
      model = M.new
      commands = []
      expected = []
      time = 0
      # Long lines of control bytes fill the ring quickly, so it wraps and
      # drops records, and a tight clock keeps the rate limit in play.
      1500.times do
        time += rng.rand(20_000_000)
        length = rng.rand(4) == 0 ? rng.rand(505) : rng.rand(40)
        bytes = rng.bytes(length) + ("\xee".b * (M::UTCB_BYTES - length))
        commands << "debug 5 #{time} #{length} #{hex(bytes)}"
        expected << "debug #{model.debug(5, time, length, bytes)}"
        next unless rng.rand(40) == 0

        cursor = rng.rand(model.next_seq + 1)
        commands << "read #{cursor} 2200" << 'state'
        expected.concat(predicted_read(model, cursor, 2200))
        expected << "state #{model.state.join(' ')}"
      end
      output, status = capture_driver(commands, driver: driver)
      status.success? && output.lines(chomp: true) == expected
    end
  end
end
