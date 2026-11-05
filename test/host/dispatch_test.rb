# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'

# kernel/core/dispatch.c and kernel/core/debug_log.c through
# test/fixtures/dispatch_driver.c, which plays a kernel's trap handler and the
# effects: register snapshots in, result words and console lines out. Seeded
# one-line mutants of the cores must each fail, so the expectations bite.
class DispatchTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c kernel/core/log.c
               kernel/generated/abi_decode.c kernel/generated/abi_run.c].freeze
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

  HANDOFF = ['console space 7: before', 'read 0 lost 0', 'reader space 7: after-one', 'reader space 7: after-two',
             'read 0 lost 0', 'read -1 lost 0', 'console space 7: parked', 'taken back',
             'console space 7: taken-back',
             'read 0 lost 0'].freeze

  # Each line once and in order across the handoff, the console writing nothing while the
  # reader holds the log, and a cursor past what was taken refused.
  def test_the_handoff_moves_each_line_once_and_in_order
    assert_equal HANDOFF, handoff_lines(@driver)
  end

  def test_a_wrapped_parked_ring_says_how_many_records_it_lost
    lines = run_driver('wrap').lines.map(&:chomp)
    lost = lines.first[/\Aconsole erx: ([0-9]+) log records lost\z/, 1]
    refute_nil lost, lines.first
    assert_equal 400, Integer(lost) + lines.drop(1).size
    assert(lines.drop(1).all? { |line| line.end_with?("space 7: #{'w' * 400}") })
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
      ["erx_debug_log_for_reader = true;", "erx_debug_log_for_reader = false;"],
      ["\terx_debug_log_for_reader = false;\n\terx_debug_log_drain();", "\terx_debug_log_for_reader = false;"],
      ["if (cursor > erx_debug_log_cursor) {", "if (cursor > UINT64_MAX - 1) {"],
      ["if (copied.lost != 0) {", "if (copied.lost == UINT64_MAX) {"]
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
                 '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'kernel/generated'),
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

  # The handoff case's lines with each record's number, time and level taken out.
  def handoff_lines(driver)
    run_driver('handoff', driver: driver).lines.map { |line| line.chomp.sub(/ #[0-9]+ [0-9]+\.[0-9]{6} [a-z]+ /, ' ') }
  end

  # Whether a driver's answers all still match what the tests above require.
  def survivors?(driver)
    good = run_driver('good', driver: driver)
    over = run_driver('over', driver: driver)
    word = run_driver('status-word', driver: driver)
    handoff_lines(driver) == HANDOFF && run_driver('wrap', driver: driver).start_with?('console erx: ') &&
      good.include?('space 7: hello') && good.start_with?('status 0 r1 0 r2 0 locks 1') &&
      over.start_with?('status -1 r1 0 r2 0 locks 0') && word.strip == format('%016x', EINVAL & 0xFFFFFFFF)
  end
end
