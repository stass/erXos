# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# kernel/core/dispatch.c and kernel/core/debug_log.c through
# test/fixtures/dispatch_driver.c, which plays a kernel's trap handler and the
# effects: register snapshots in, result words and console lines out. Seeded
# one-line mutants of the cores must each fail, so the expectations bite.
class DispatchTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c kernel/core/log.c
               build/gen/kernel/generated/abi_decode.c build/gen/kernel/generated/abi_run.c].freeze
  DRIVER = 'test/fixtures/dispatch_driver.c'
  # A trap's status is two's complement in the low 32 bits of the word.
  EINVAL = -1
  ENOTSUP = -12

  def setup
    @directory = Dir.mktmpdir('erx-dispatch-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @driver = build
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_a_good_call_logs_its_text_under_the_callers_number
    assert_equal({ status: 0, results: [0, 0], locks: 1, console: ['space 7: hello'] }, call('good'))
  end

  def test_an_empty_line_still_opens_with_the_callers_number
    assert_equal ['space 7: '], call('empty').fetch(:console)
  end

  def test_arguments_the_call_does_not_use_change_nothing
    assert_equal({ status: 0, results: [0, 0], locks: 1, console: ['space 7: hello'] }, call('garbage'))
  end

  def test_a_length_past_the_message_words_is_refused_before_the_lock
    %w[over high-bits u32-max u64-max].each do |name|
      assert_equal({ status: EINVAL, results: [0, 0], locks: 0, console: [] }, call(name), name)
    end
  end

  def test_an_unknown_call_number_is_refused_before_the_lock
    %w[number-zero number-next number-max].each do |name|
      assert_equal({ status: ENOTSUP, results: [0, 0], locks: 0, console: [] }, call(name), name)
    end
  end

  def test_the_status_is_zero_extended_from_its_32_bits
    assert_equal format('%016x', EINVAL & 0xFFFFFFFF), run_driver('status-word').strip
  end

  def test_the_longest_line_of_controls_is_whole_and_escaped
    line = call('full-controls').fetch(:console).first
    assert_equal "space 7: #{'\\x01' * 504}", line
  end

  def test_text_cannot_forge_the_prefix_or_a_second_line
    console = call('forged').fetch(:console)
    assert_equal 1, console.size
    assert console.first.start_with?('space 7: x\\x0Aerx: panic'), console.first
  end

  def test_each_space_has_its_own_limit_and_its_own_count
    assert_equal ['other passes', 'flooder counted'], run_driver('two-spaces').lines.map(&:strip)
  end

  HANDOFF = ['console space 7: before',
             'erx_console take 0 lost 0', 'erx_console space 7: after-one', 'erx_console space 7: after-two',
             'erx_console take 0 lost 0',
             'reader read 0 lost 0', *%w[before after-one after-two parked].map { |text| "reader space 7: #{text}" },
             'reader read -1 lost 0',
             'console space 7: parked', 'taken back', 'console space 7: taken-back',
             'erx_console take 0 lost 0'].freeze

  # Each line once and in order across the handoff, the early console writing nothing while
  # the console takes the log, a read from the start seeing every line, a cursor past the
  # newest record refused, and a take finding nothing once the log is taken back.
  def test_the_handoff_moves_each_line_once_and_in_order
    assert_equal HANDOFF, handoff_lines(@driver)
  end

  LONG = "space 7: #{'l' * 500}".freeze
  # A window of ERX_LOG_RECORD_MAX holds the four short records and three of the long ones.
  READERS = ['console space 7: boot-one', 'console space 7: boot-two',
             'other read 0 lost 0', *%w[boot-one boot-two after-one].map { |text| "other space 7: #{text}" },
             'other read 0 lost 0', 'other space 7: after-two',
             'erx_console take 0 lost 0', 'erx_console space 7: after-one', 'erx_console space 7: after-two',
             'short read 0 lost 0', *%w[boot-one boot-two after-one after-two].map { |text| "short space 7: #{text}" },
             *(["short #{LONG}"] * 3),
             'erx_console take 0 lost 0', *(["erx_console #{LONG}"] * 4),
             'other read 0 lost 0', *(["other #{LONG}"] * 4), 'other space 7: parked',
             'taken back', 'console space 7: parked'].freeze

  # Another reader from the start sees every line, the console none of the early console's
  # twice and none lost across a second map of the UART, and no read but the console's take
  # moves what taking the log back writes.
  def test_another_reader_sees_every_line_and_takes_none_from_the_console
    assert_equal READERS, readers_lines(@driver)
  end

  def test_a_wrapped_parked_ring_says_how_many_records_it_lost
    console, reader = run_driver('wrap').lines.map(&:chomp).partition { |line| line.start_with?('console ') }
    lost = console.first[/\Aconsole erx: ([0-9]+) log records lost\z/, 1]
    refute_nil lost, console.first
    assert_equal 400, Integer(lost) + console.drop(1).size
    assert(console.drop(1).all? { |line| line.end_with?("space 7: #{'w' * 400}") })
    assert_equal "reader read 0 lost #{lost}", reader.first
  end

  MUTANTS = {
    'kernel/core/dispatch.c' => [
      ["results[index] = 0;", "results[index] = results[0];"],
      ["results[0] = (uint64_t)(uint32_t)status;", "results[0] = (uint64_t)(int64_t)status;"]
    ],
    'kernel/core/debug_log.c' => [
      ["\t\terx_debug_log_drain();\n", "\t\t(void)erx_debug_log_drain;\n"],
      ["caller->space,", "(uint64_t)0,"],
      # The handoff never switches the sink. Seeded at the write: dropping the read leaves the
      # flag set but unused, which LLVM 23 refuses under -Werror.
      ["erx_debug_log_for_console = true;", "erx_debug_log_for_console = false;"],
      ["\terx_debug_log_for_console = false;\n\terx_debug_log_drain();", "\terx_debug_log_for_console = false;"],
      ["if (copied.lost != 0) {", "if (copied.lost == UINT64_MAX) {"],
      # A cursor read that moves the shared position, so it takes lines from the console.
      ["\tcopied = erx_log_copy(&erx_debug_log_ring, cursor, window, window_size);\n",
       "\tcopied = erx_log_copy(&erx_debug_log_ring, cursor, window, window_size);\n" \
       "\tif (copied.status == ERX_OK)\n\t\terx_debug_log_taken = copied.next_cursor;\n"],
      # A cursor read refused past the shared position, so a reader ahead of the console fails.
      ["\tcopied = erx_log_copy(&erx_debug_log_ring, cursor, window, window_size);\n",
       "\tif (cursor > erx_debug_log_taken) {\n\t\terx_effect_log_unlock();\n" \
       "\t\treturn ((erx_log_copy_result_t){ .status = ERX_EINVAL, .next_cursor = cursor });\n\t}\n" \
       "\tcopied = erx_log_copy(&erx_debug_log_ring, cursor, window, window_size);\n"],
      # A console take that ignores the shared position and starts at the oldest record.
      ["erx_log_copy(&erx_debug_log_ring, erx_debug_log_taken, window, window_size);",
       "erx_log_copy(&erx_debug_log_ring, 0, window, window_size);"],
      # A console take that leaves the shared position where it was.
      ["\tif (copied.status == ERX_OK)\n\t\terx_debug_log_taken = copied.next_cursor;\n\terx_effect_log_unlock();",
       "\terx_effect_log_unlock();"]
    ]
  }.freeze

  def test_seeded_mutants_fail
    MUTANTS.each do |source, pairs|
      pairs.each do |from, to|
        text = File.read(File.join(ROOT, source))
        assert_includes text, from
        mutated = File.join(@directory, 'mutated.c')
        File.write(mutated, text.sub(from, to))
        driver = build(name: 'mutant', replace: { source => mutated })
        refute survivors?(driver), "#{source}: #{from.inspect} survived"
      end
    end
  end

  private

  def build(name: 'dispatch', replace: {})
    sources = SOURCES.map { |source| replace.fetch(source) { File.join(ROOT, source) } }
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    output = File.join(@directory, name)
    @runner.run([ENV.fetch('CC', 'cc'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 *Erx::Generated.include_flags(root: ROOT),
                 '-I', File.join(ROOT, 'include'), '-I', Erx::Generated.path('kernel/generated', root: ROOT),
                 '-I', File.join(ROOT, 'kernel/core'), *sources, File.join(ROOT, DRIVER), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def run_driver(name, driver: @driver)
    output, status = Open3.capture2e(driver, name, stdin_data: '')
    raise Erx::Error, "driver #{name}: #{output}" unless status.success?

    output
  end

  # One call's report: `status S r1 R r2 R locks N`, then one line per console line.
  def call(name)
    report, *console = run_driver(name).lines.map(&:chomp)
    fields = report.split
    { status: fields[1].to_i, results: [fields[3].to_i, fields[5].to_i], locks: fields[7].to_i,
      console: console.map { |line| line.sub(/\A#[0-9]+ [0-9]+\.[0-9]{6} [a-z]+ /, '') } }
  end

  # A case's lines with each record's number, time and level taken out.
  def record_lines(name, driver)
    run_driver(name, driver: driver).lines.map { |line| line.chomp.sub(/ #[0-9]+ [0-9]+\.[0-9]{6} [a-z]+ /, ' ') }
  end

  def handoff_lines(driver) = record_lines('handoff', driver)

  def readers_lines(driver) = record_lines('readers', driver)

  # Whether a driver's answers all still match what the tests above require.
  def survivors?(driver)
    good = run_driver('good', driver: driver)
    over = run_driver('over', driver: driver)
    word = run_driver('status-word', driver: driver)
    handoff_lines(driver) == HANDOFF && readers_lines(driver) == READERS &&
      run_driver('wrap', driver: driver).start_with?('console erx: ') &&
      good.include?('space 7: hello') && good.start_with?('status 0 r1 0 r2 0 locks 1') &&
      over.start_with?('status -1 r1 0 r2 0 locks 0') && word.strip == format('%016x', EINVAL & 0xFFFFFFFF)
  end
end
