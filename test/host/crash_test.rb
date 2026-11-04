# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/crash_frame'
require_relative '../../tools/fuzz/crash_frame'
require_relative '../../tools/lib/erx/runner'

# Judges the crash record and the crash frame on both sides: the C17 core's
# writer, checker and reader through test/fixtures/crash_driver.c, and the
# harness's reader in tools/lib/erx/crash_frame.rb, which is written apart from
# it. Every refusal is asked of both, and seeded mutations of written frames
# must get the same answer from both.
class CrashTest < Minitest::Test
  FRAME = Erx::CrashFrame
  CODEC = FRAME::CODEC
  BRIEF = FRAME::FORMS.fetch('brief')
  FULL = FRAME::FORMS.fetch('full')
  CAUSE = FRAME::CAUSE
  NORMAL = CODEC.member('boot_value', 'normal')
  TRIAL = CODEC.member('boot_value', 'trial')
  UNKNOWN = CODEC.member('boot_value', 'unknown')
  SLOT_A = CODEC.member('boot_slot', 'a')
  SLOT_B = CODEC.member('boot_slot', 'b')
  SLOT_NONE = CODEC.member('boot_slot', 'none')
  EXIT = CODEC.member('fault_kind', 'exit')
  MEMORY = CODEC.member('fault_kind', 'memory')
  CRC_OFFSET = FRAME::CRC_START - 4
  CAUSE_OFFSET = 24
  DRIVER_SECONDS = 30

  ReadAnswer = Data.define(:status, :reason, :check, :length, :frame_start, :frame_end, :record)
  Written = Data.define(:length, :check, :record, :frame)

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-crash-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported crash-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @commands = 0
    @driver = build_driver(core_sources, name: 'crash')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def core_sources = %w[crash.c crash_frame.c crash_read.c log.c].map { |file| File.join(@root, 'kernel/core', file) }

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(sources, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, '-I', File.join(@root, 'include'), *sources,
                 File.join(@root, 'test/fixtures/crash_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def drive(commands, driver: @driver)
    @commands += 1
    input = File.join(@directory, "commands-#{@commands}")
    File.write(input, commands.join("\n") << "\n")
    log = File.join(@directory, "output-#{@commands}")
    pid = Process.spawn('gtimeout', '-k', '5', DRIVER_SECONDS.to_s, driver, input, out: log, err: "#{log}.err", in: File::NULL)
    _, status = Process.wait2(pid)
    assert status.success?, "driver failed: #{File.read("#{log}.err")}"
    File.readlines(log, chomp: true)
  end

  def hex(bytes) = bytes.empty? ? '-' : bytes.unpack1('H*')
  def unhex(text) = text == '-' ? ''.b : [text].pack('H*')

  # Everything the driver's write command takes, each with a usable default.
  def write(form: FULL, cause: CAUSE.fetch(:panic), cpu: 1, value: NORMAL, slot: SLOT_A, nframes: 3, frames: 1, regs: 1,
            kind: 0, message: 'boom', lines: 2)
    message_hex = message.nil? ? '-' : message.b.unpack1('H*')
    answer = drive(["write #{form} #{cause} #{cpu} #{value} #{slot} #{nframes} #{frames} #{regs} #{kind} " \
                    "#{message_hex.empty? ? '-' : message_hex} #{lines}"])
    _, length, check, record = answer.fetch(0).split
    Written.new(length: length.to_i, check: check, record: unhex(record),
                frame: unhex(answer.fetch(1).split.fetch(1)).delete_prefix("\n"))
  end

  def read_c(log)
    fields = drive(["read #{hex(log.b)}"]).fetch(0).split
    ReadAnswer.new(status: fields[1].to_sym, reason: fields[2].to_sym, check: fields[3].to_sym, length: fields[4].to_i,
                   frame_start: fields[5].to_i, frame_end: fields[6].to_i, record: unhex(fields[7]))
  end

  def check_c(bytes) = drive(["check #{hex(bytes)}"]).fetch(0).split.fetch(1).to_sym

  # Both readers give one answer for this log; returns the Ruby reader's.
  def read_both(log)
    ruby = FRAME.read(log)
    assert_same_answer(read_c(log), ruby, log)
    ruby
  end

  def assert_same_answer(native, ruby, log)
    label = hex(log.b[0, 200])
    assert_equal native.status, ruby.status, label
    assert_equal native.reason, ruby.reason || :none, label
    assert_equal native.check, ruby.check || :not_run, label
    assert_equal native.length, ruby.length, label
    if ruby.status == :valid
      assert_equal :ok, FRAME.check(native.record), label
      assert_equal ruby.text, native.record.byteslice(FRAME::RECORD_SIZE..) || '', label
      assert_equal CODEC.decode_layout('erx_crash_brief', native.record, prefix: true).fetch('crc'), ruby.record.fetch('crc'), label
    else
      assert_equal ''.b, native.record, label
      kept = log.b.byteslice(native.frame_start, native.frame_end - native.frame_start).byteslice(0, FRAME::KEPT_BYTES_MAX)
      assert_equal kept, ruby.lines.join, label
    end
  end

  # A record with one change and its CRC made right again, so that the change
  # itself is what the check must see.
  def recrc(record)
    fixed = record.b.dup
    crc = FRAME.crc32c(fixed.byteslice(FRAME::CRC_START..))
    fixed[CRC_OFFSET, 4] = [crc].pack('L<')
    fixed
  end

  def patch(record, offset, bytes)
    changed = record.b.dup
    changed[offset, bytes.bytesize] = bytes.b
    recrc(changed)
  end

  def frame_of(record, **header) = Erx::CrashFrameFuzz.frame_of(record, **header)

  # The vectors of RFC 3720, B.4, and the catalogue's check value.
  def test_crc32c_matches_published_vectors
    vectors = { '123456789' => 0xe3069283, "\0".b * 32 => 0x8a9136aa, "\xff".b * 32 => 0x62a8ab43 }
    vectors.each do |bytes, expected|
      assert_equal expected, FRAME.crc32c(bytes)
      assert_equal "crc #{expected}", drive(["crc #{hex(bytes.b)}"]).fetch(0)
    end
  end

  def test_every_cause_in_both_forms_writes_a_valid_record_and_frame
    faults = { fault: MEMORY, halt: EXIT, watchdog: 0, panic: 0 }
    [BRIEF, FULL].product(faults.to_a).each do |form, (cause, kind)|
      written = write(form: form, cause: CAUSE.fetch(cause), kind: kind)
      assert_equal 'ok', written.check
      assert_equal :ok, FRAME.check(written.record)
      result = read_both(written.frame)
      assert_equal :valid, result.status
      assert_equal CAUSE.fetch(cause), result.record.fetch('cause')
      assert_equal form, result.record.fetch('form')
      assert_equal 'BUILDID8', result.record.fetch('build_id')
      assert_equal 0x1122334455667788, result.record.fetch('uptime_ns')
      assert_equal 5_000_000_000, result.record.fetch('since_pet_ns')
      assert_equal written.record, read_c(written.frame).record
    end
  end

  def test_the_brief_form_is_120_bytes_and_carries_nothing_else
    written = write(form: BRIEF, cause: CAUSE.fetch(:fault), kind: MEMORY, message: 'passphrase', lines: 4)
    assert_equal FRAME::BRIEF_SIZE, written.length
    assert_equal 120, written.length
    refute_includes written.record, 'passphrase'
    refute_includes written.record, 'log'
    assert_equal 0, FRAME.read(written.frame).record.fetch('nframes')
    assert_equal '', FRAME.read(written.frame).text
  end

  def test_a_form_outside_the_enum_writes_the_brief_form
    written = write(form: 99, message: 'secret')
    assert_equal 'ok', written.check
    assert_equal FRAME::BRIEF_SIZE, written.length
  end

  def test_an_input_that_contradicts_itself_is_written_as_a_panic
    { 'unknown cause' => { cause: 77 },
      'zero cause' => { cause: 0 },
      'fault with no kind' => { cause: CAUSE.fetch(:fault), kind: 0 },
      'fault with an unknown kind' => { cause: CAUSE.fetch(:fault), kind: 99 },
      'halt without exit' => { cause: CAUSE.fetch(:halt), kind: MEMORY },
      'watchdog with a fault' => { cause: CAUSE.fetch(:watchdog), kind: MEMORY },
      'cpu at the limit' => { cause: CAUSE.fetch(:watchdog), cpu: FRAME::CPU_LIMIT } }.each do |name, input|
      written = write(**input)
      assert_equal 'ok', written.check, name
      assert_equal CAUSE.fetch(:panic), FRAME.read(written.frame).record.fetch('cause'), name
    end
    assert_equal 0, FRAME.read(write(cpu: FRAME::CPU_LIMIT).frame).record.fetch('cpu')
    assert_equal FRAME::CPU_LIMIT - 1, FRAME.read(write(cpu: FRAME::CPU_LIMIT - 1).frame).record.fetch('cpu')
  end

  def test_a_boot_pair_outside_the_machine_pages_is_written_as_unknown
    [[UNKNOWN, SLOT_A], [NORMAL, SLOT_NONE], [TRIAL, SLOT_NONE], [0, 0], [9, SLOT_A], [NORMAL, 9]].each do |value, slot|
      record = FRAME.read(write(value: value, slot: slot).frame).record
      assert_equal [UNKNOWN, SLOT_NONE], [record.fetch('boot_value'), record.fetch('boot_slot')]
    end
    [[UNKNOWN, SLOT_NONE], [NORMAL, SLOT_A], [NORMAL, SLOT_B], [TRIAL, SLOT_A], [TRIAL, SLOT_B]].each do |value, slot|
      record = FRAME.read(write(value: value, slot: slot).frame).record
      assert_equal [value, slot], [record.fetch('boot_value'), record.fetch('boot_slot')]
    end
  end

  def test_only_a_panic_keeps_frames_and_only_fault_and_panic_keep_registers
    panic = FRAME.read(write(nframes: 3).frame).record
    assert_equal 3, panic.fetch('nframes')
    assert_equal [0x1000, 0x1001, 0x1002, 0], panic.fetch('frames').first(4)
    assert_equal 64, FRAME.read(write(nframes: 100).frame).record.fetch('nframes')
    assert_equal 0x103f, FRAME.read(write(nframes: 100).frame).record.fetch('frames').last
    assert_equal 0, FRAME.read(write(frames: 0).frame).record.fetch('nframes')
    assert_equal 0x5a5a5a5a5a5a5a5a, panic.fetch('regs').fetch('pc')
    assert_equal 0, FRAME.read(write(regs: 0).frame).record.fetch('regs').fetch('pc')

    fault = FRAME.read(write(cause: CAUSE.fetch(:fault), kind: MEMORY).frame).record
    assert_equal 0, fault.fetch('nframes')
    assert_equal 0x5a5a5a5a5a5a5a5a, fault.fetch('regs').fetch('pc')
    halt = FRAME.read(write(cause: CAUSE.fetch(:halt), kind: EXIT).frame).record
    assert_equal 0, halt.fetch('regs').fetch('pc')
    watchdog = FRAME.read(write(cause: CAUSE.fetch(:watchdog)).frame).record
    assert_equal 0, watchdog.fetch('regs').fetch('pc')
    assert_equal 0, watchdog.fetch('fault').fetch('kind')
  end

  def test_the_message_is_escaped_and_comes_before_the_log
    written = write(message: "bad\e]0;owned\a\nline\xFF", lines: 2)
    text = FRAME.read(written.frame).text
    assert_equal 'ok', written.check
    assert_match(/\A[\x20-\x7e\n]*\z/n, text)
    first, *rest = text.split("\n")
    refute_includes first, "\e"
    assert_includes first, 'bad'
    assert_includes first, 'line'
    assert_equal 2, rest.size
    assert_includes rest.first, 'line 0'
    assert_includes rest.last, 'line 1'
  end

  def test_no_message_and_no_log_leave_no_text
    written = write(message: nil, lines: -1)
    assert_equal FRAME::RECORD_SIZE, written.length
    assert_equal '', FRAME.read(written.frame).text
  end

  def test_the_longest_record_keeps_the_newest_whole_lines_and_fits_the_frame
    written = write(message: 'x' * 3000, lines: 800)
    assert_equal 'ok', written.check
    assert_operator written.length, :<=, FRAME::CRASH_SIZE
    assert_operator written.length, :>, FRAME::CRASH_SIZE - 200
    result = read_both(written.frame)
    assert_equal :valid, result.status
    lines = result.text.split("\n")
    assert_includes lines.last, 'line 799'
    numbers = lines.drop(1).map { |line| line[/line (\d+) of/, 1].to_i }
    assert_equal (numbers.first..799).to_a, numbers
    assert_operator written.frame.lines.size, :<=, CODEC.constant('crash_frame_lines_max') + 2
    written.frame.lines[1...-3].each { |line| assert_equal FRAME::LINE_CHARS + 1, line.bytesize }
  end

  # Memory corruption is a common reason to panic: the walk of the log must end
  # however wrong its counters are, or the machine never does.
  def test_corrupted_log_counters_do_not_stop_the_record
    written = write(lines: -2)
    assert_equal 'ok', written.check
    assert_equal :valid, FRAME.read(written.frame).status
  end

  def test_a_buffer_full_of_stale_bytes_does_not_reach_the_record
    # The driver fills the buffer with 0xa5 and fails on a byte past the length.
    written = write(form: BRIEF)
    refute_includes written.record, "\xA5".b
  end

  def refusals(full, brief)
    {
      magic: patch(brief, 0, "\0" * 8),
      version: patch(brief, 8, [1].pack('L<')),
      length: patch(brief, 12, [121].pack('L<')),
      form: patch(brief, 20, [3].pack('L<')),
      crc: brief.dup.tap { |record| record.setbyte(100, record.getbyte(100) ^ 1) },
      cause: patch(brief, CAUSE_OFFSET, [5].pack('L<')),
      cpu: patch(brief, 28, [FRAME::CPU_LIMIT].pack('L<')),
      boot: patch(brief, 60, [SLOT_NONE].pack('L<')),
      padding: patch(brief, FRAME::PADDING.begin, "\1"),
      nframes: patch(brief, 64, [1].pack('L<')),
      fault: patch(patch(brief, CAUSE_OFFSET, [CAUSE.fetch(:fault)].pack('L<')), 72, [99].pack('L<')),
      regs: patch(patch(full, CAUSE_OFFSET, [CAUSE.fetch(:watchdog)].pack('L<')).then { |record| zero_frames(record) },
                  FRAME::REGS_OFFSET, "\1"),
      frames: patch(full, FRAME::RECORD_SIZE - 8, "\1"),
      text: patch(full, FRAME::RECORD_SIZE, "\e")
    }
  end

  def zero_frames(record)
    patch(patch(record, 64, [0].pack('L<')), FRAME::FRAMES_OFFSET, "\0".b * (FRAME::RECORD_SIZE - FRAME::FRAMES_OFFSET))
  end

  def clean_records
    brief = write(form: BRIEF, cause: CAUSE.fetch(:watchdog)).record
    full = write(form: FULL, cause: CAUSE.fetch(:panic), regs: 0, nframes: 0, lines: 1).record
    [full, brief]
  end

  def test_each_check_refuses_on_both_sides
    full, brief = clean_records
    assert_equal :ok, FRAME.check(full)
    assert_equal :ok, check_c(brief)
    refusals(full, brief).each do |name, record|
      assert_equal name, FRAME.check(record), "ruby #{name}"
      assert_equal name, check_c(record), "c #{name}"
    end
    assert_equal :short, check_c(brief.byteslice(0, 119))
    assert_equal :short, FRAME.check(brief.byteslice(0, 119))
    assert_equal :short, check_c(full.byteslice(0, full.bytesize - 1))
    assert_equal :short, FRAME.check(full.byteslice(0, full.bytesize - 1))
    assert_equal :length, check_c(patch(full, 12, [FRAME::RECORD_SIZE - 1].pack('L<')))
    assert_equal :length, check_c(patch(full, 12, [FRAME::CRASH_SIZE + 1].pack('L<')))
  end

  def test_an_all_zero_or_max_field_never_overruns_the_check
    %W[#{"\0".b * 120} #{"\xFF".b * 120} #{"\xFF".b * 16_384}].each do |bytes|
      assert_equal :magic, check_c(bytes)
      assert_equal :magic, FRAME.check(bytes)
    end
  end

  def test_the_frame_refusals_of_the_design
    full, brief = clean_records
    good = frame_of(brief)
    assert_equal :valid, read_both(good).status

    lines = good.lines
    cut = read_both(lines[0...-1].join)
    assert_equal %i[truncated cut], [cut.status, cut.reason]
    early = read_both((lines[0...-2] + [lines[-1]]).join)
    assert_equal %i[truncated early_end], [early.status, early.reason]
    assert_equal %i[truncated cut], read_both(good.byteslice(0, 40)).then { |r| [r.status, r.reason] }

    flipped = good.dup
    second_line = lines[0].bytesize + lines[1].bytesize + 10
    flipped.setbyte(second_line, flipped.getbyte(second_line) == 65 ? 66 : 65)
    assert_equal %i[corrupt record], read_both(flipped).then { |r| [r.status, r.reason] }
    assert_equal :crc, FRAME.read(flipped).check

    says_full = frame_of(brief, form_name: 'full', length: full.bytesize)
    assert_equal %i[corrupt line_length], read_both(says_full).then { |r| [r.status, r.reason] }
    brief_header = frame_of(full, form_name: 'brief', length: full.bytesize)
    assert_equal %i[corrupt header], read_both(brief_header).then { |r| [r.status, r.reason] }

    full_says_brief = frame_of(patch(full, 20, [BRIEF].pack('L<')))
    assert_equal :length, read_both(full_says_brief).check
    bad_pair = frame_of(patch(brief, 60, [SLOT_NONE].pack('L<')))
    assert_equal :boot, read_both(bad_pair).check
    padded = frame_of(patch(brief, FRAME::PADDING.begin, "\1"))
    assert_equal :padding, read_both(padded).check
  end

  def test_a_record_whose_length_differs_from_its_frames_is_refused
    full = write(form: FULL, lines: 1).record
    assert_equal :length, read_both(frame_of(full + 'a')).check
    assert_equal :short, read_both(frame_of(patch(full, 12, [full.bytesize + 1].pack('L<')))).check
  end

  def test_header_and_line_shapes
    _, brief = clean_records
    good = frame_of(brief)
    rest = good.lines.drop(1).join
    { "#{FRAME::BEGIN_MARKER}\n" => :header,
      "#{FRAME::BEGIN_MARKER} \n" => :header,
      "#{FRAME::BEGIN_MARKER} brief\n" => :header,
      "#{FRAME::BEGIN_MARKER} brief 0120\n" => :header,
      "#{FRAME::BEGIN_MARKER} brief 121\n" => :header,
      "#{FRAME::BEGIN_MARKER} brief 120 \n" => :header,
      "#{FRAME::BEGIN_MARKER}  brief 120\n" => :header,
      "#{FRAME::BEGIN_MARKER} full 903\n" => :header,
      "#{FRAME::BEGIN_MARKER} full 16385\n" => :header,
      "#{FRAME::BEGIN_MARKER} full 99999999999999999999\n" => :header,
      "#{FRAME::BEGIN_MARKER} huge 120\n" => :header }.each do |header, reason|
      answer = read_both(header + rest)
      assert_equal [:corrupt, reason], [answer.status, answer.reason], header
    end
    assert_equal :absent, read_both("#{FRAME::BEGIN_MARKER}ning brief 120\nrest\n").status
    assert_equal :absent, read_both('').status
    assert_equal :absent, read_both("just a log\nwith lines\n").status
    assert_equal :absent, read_both("no newline at all").status
    second = good.lines.insert(1, good.lines[0]).join
    assert_equal :second_header, read_both(second).reason
    second_end = (good.lines[0...-1] + [good.lines[0], good.lines[-1]]).join
    assert_equal :second_header, read_both(second_end).reason
    assert_equal :no_end, read_both((good.lines[0...-1] + ["text\n", good.lines[-1]]).join).reason
    assert_equal :valid, read_both("before\nmore\n#{good}after\n").status
    assert_equal :valid, read_both(good.gsub("\n", "\r\n")).status
    assert_equal :line_length, read_both(good.lines.then { |l| l[1] = "A#{l[1]}"; l }.join).reason
    assert_equal :base64, read_both(good.lines.then { |l| l[1] = "#{'!' * FRAME::LINE_CHARS}\n"; l }.join).reason
  end

  # A frame of a full-form length whose last line ends in group: 905 bytes end
  # in a group of two bytes and 907 in a group of one.
  def frame_with_last(length, group)
    count = (length - 1) / FRAME::LINE_BYTES
    filler = 'A' * (((length - 1) % FRAME::LINE_BYTES + 3) / 3 - 1) * 4
    ["#{FRAME::BEGIN_MARKER} full #{length}", *Array.new(count, 'A' * FRAME::LINE_CHARS), filler + group, FRAME::END_MARKER].join("\n") << "\n"
  end

  def test_base64_has_one_spelling
    { [905, 'AAQ='] => :record, [905, 'AAR='] => :base64, [907, 'AQ=='] => :record, [907, 'AR=='] => :base64,
      [905, 'AA=='] => :base64, [907, 'AAA='] => :base64, [905, 'A=A='] => :base64, [907, '=A=='] => :base64 }.each do |(length, group), reason|
      answer = read_both(frame_with_last(length, group))
      assert_equal [:corrupt, reason], [answer.status, answer.reason], "#{length} #{group}"
    end
    lines = frame_of(clean_records.last).lines
    padded_where_none = "#{lines[1].chomp[0...-1]}=\n"
    assert_equal :base64, read_both([lines[0], padded_where_none, *lines[2..]].join).reason
  end

  def test_the_two_readers_agree_on_mutated_frames
    full, brief = clean_records
    random = Random.new(36)
    seeds = [frame_of(full), frame_of(brief), "text\n#{frame_of(brief)}tail\n"]
    400.times do
      bytes = seeds.sample(random: random).b.dup
      random.rand(1..3).times do
        next if bytes.empty?

        case random.rand(5)
        when 0 then bytes.setbyte(random.rand(bytes.bytesize), random.rand(256))
        when 1 then bytes = bytes.byteslice(0, random.rand(bytes.bytesize))
        when 2 then bytes.setbyte(random.rand(bytes.bytesize), 10)
        when 3 then bytes.insert(random.rand(bytes.bytesize), %W[= \r \n #{FRAME::END_MARKER}\n].sample(random: random))
        else bytes.setbyte(bytes.index("\n", random.rand(bytes.bytesize)) || 0, 65)
        end
      end
      read_both(bytes)
    end
  end

  def test_frame_offsets_keep_the_failed_frames_lines
    _, brief = clean_records
    frame = frame_of(brief)
    log = "before\n#{frame[0...-5]}x\nafter\n"
    native = read_c(log)
    ruby = FRAME.read(log)
    assert_equal 'before'.size + 1, native.frame_start
    assert_equal log.byteslice(native.frame_start, native.frame_end - native.frame_start), ruby.lines.join
    assert_equal :no_end, ruby.reason
  end

  def test_the_report_escapes_everything_it_prints
    _, brief = clean_records
    poisoned = frame_of(brief).lines
    poisoned[1] = "\e]0;owned\a\u202e#{'A' * 40}\n"
    report = FRAME.report(FRAME.read(poisoned.join))
    report.each { |line| assert_match(/\A[\x20-\x7e]*\z/, line) }
    refute_empty report.grep(/\\u\{1b\}/)

    valid = FRAME.report(FRAME.read(write(message: "a\e[31m").frame))
    valid.each { |line| assert_match(/\A[\x20-\x7e]*\z/, line) }
    assert_equal 'crash frame: absent', FRAME.report(FRAME.read('')).first
  end

  def test_the_banner_hides_a_frame_before_it
    _, brief = clean_records
    frame = frame_of(brief)
    assert_equal :absent, FRAME.read(frame, after: 'banner').status
    assert_equal :absent, FRAME.read("#{frame}banner\n", after: 'banner').status
    assert_equal :valid, FRAME.read("banner\n#{frame}", after: 'banner').status
    assert_equal :valid, FRAME.read("#{frame.sub('brief', 'bad')}banner\n#{frame}", after: 'banner').status
  end

  def plan(form, bytes) = drive(["plan #{form} #{hex(bytes)}"]).fetch(0).split.fetch(1).to_i

  def test_only_a_record_of_the_builds_form_is_handed_on
    full, brief = clean_records
    assert_equal brief.bytesize, plan(BRIEF, brief)
    assert_equal full.bytesize, plan(FULL, full)
    assert_equal brief.bytesize, plan(BRIEF, brief + "\xEE".b * 4096)
    assert_equal 0, plan(BRIEF, full)
    assert_equal 0, plan(FULL, brief)
    assert_equal 0, plan(BRIEF, brief.dup.tap { |record| record.setbyte(100, record.getbyte(100) ^ 1) })
    assert_equal 0, plan(BRIEF, brief.byteslice(0, 119))
    assert_equal 0, plan(BRIEF, "\xEE".b * 4096)
    assert_equal 0, plan(BRIEF, "\0".b * 4096)
    assert_equal 0, plan(BRIEF, ''.b)
  end

  # One-line mutants of the core: each must change what these cases see.
  MUTANTS = {
    'crash.c' => [
      ['the CRC starts a field early', '#define ERX_CRASH_CRC_START	(ERX_CRASH_BRIEF_OFF_CRC + sizeof(uint32_t))',
       '#define ERX_CRASH_CRC_START	(ERX_CRASH_BRIEF_OFF_CRC + sizeof(uint16_t))'],
      ['the text check lets a control byte through', "byte != '\\n' && (byte < 0x20 || byte > 0x7e)",
       "byte != '\\n' && (byte < 0x1b || byte > 0x7e)"],
      ['the CPU limit is off by one', 'header.cpu >= ERX_CPU_LIMIT', 'header.cpu > ERX_CPU_LIMIT'],
      ['the writer leaves the buffer', '__builtin_memset(buffer, 0, ERX_CRASH_SIZE);', '(void)0;'],
      ['the message goes unescaped', 'escaped = erx_log_escape(input->message, input->message_length,
		    text, ERX_CRASH_MESSAGE_MAX);', "__builtin_memcpy(text, input->message, input->message_length);
		escaped = (erx_log_escape_result_t){ .written = input->message_length };"]
    ],
    'crash_read.c' => [
      ['a header length is unbounded', 'header->length <= ERX_CRASH_SIZE', 'header->length <= ERX_CRASH_SIZE + 1'],
      ['padding bits go unchecked', '(have < 2 && (group & 0xff00) != 0)', '(have < 1 && (group & 0xff00) != 0)']
    ]
  }.freeze

  def test_the_cases_catch_seeded_mutants
    probes = lambda do |driver|
      full, brief = [write_with(driver, form: FULL, lines: 0, regs: 0, nframes: 0), write_with(driver, form: BRIEF)]
      [check_answers(driver, full, brief), read_answers(driver, brief)]
    end
    baseline = probes.call(@driver)
    MUTANTS.each_with_index do |(file, mutants), group|
      mutants.each_with_index do |(name, from, to), index|
        path = File.join(@root, 'kernel/core', file)
        source = File.read(path)
        assert_equal 1, source.scan(from).size, "mutant #{name} must edit exactly one place"
        mutated = File.join(@directory, "mutant-#{group}-#{index}.c")
        File.write(mutated, source.sub(from) { to })
        sources = core_sources.map { |core| core == path ? mutated : core }
        driver = build_driver(sources, name: "mutant-#{group}-#{index}")
        changed = begin
          probes.call(driver) != baseline
        rescue Minitest::Assertion
          true
        end
        assert changed, "mutant survived: #{name}"
      end
    end
  end

  def write_with(driver, form:, lines: 1, regs: 1, nframes: 1)
    answer = drive(["write #{form} #{CAUSE.fetch(:panic)} 1 #{NORMAL} #{SLOT_A} #{nframes} 1 #{regs} 0 #{hex("m\ek".b)} #{lines}"],
                   driver: driver)
    unhex(answer.fetch(0).split.fetch(3))
  end

  # One bit flipped either side of the CRC's start, the CPU's limit and a
  # control byte in the text; and the Ruby side's view of what the driver wrote.
  def check_answers(driver, full, brief)
    flip = ->(offset) { brief.dup.tap { |record| record.setbyte(offset, record.getbyte(offset) ^ 1) } }
    cases = [brief, full, patch(brief, 28, [FRAME::CPU_LIMIT].pack('L<')), patch(full, FRAME::RECORD_SIZE, "\e"),
             *(CRC_OFFSET - 4...CRC_OFFSET + 8).map(&flip)]
    drive(cases.map { |bytes| "check #{hex(bytes)}" }, driver: driver) + [full, brief, FRAME.check(full), FRAME.check(brief)]
  end

  def read_answers(driver, brief)
    too_long = "#{FRAME::BEGIN_MARKER} full #{FRAME::CRASH_SIZE + 1}\n"
    drive([frame_of(brief), too_long, frame_with_last(907, 'AR==')].map { |log| "read #{hex(log.b)}" }, driver: driver)
  end
end
