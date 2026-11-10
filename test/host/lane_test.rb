# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the lane's reader and writer (liberx/erx_lane.c) through their host
# driver, test/fixtures/lane_driver.c, which plays the other party and
# compares every result with an independent model of the party's position.
# Bounds for the reader: the exploration's 207 scenarios (records of 0 to
# 100 bytes, one to three of them, three start positions, buffers of 0, 5,
# 16 and unbounded bytes, a 64-byte area) under every interleaving of takes,
# armed takes, publications and the producer's two-step wait; the cuts at
# every 16-byte boundary of a record longer than the lane; the limits at
# every bound. For the writer: 1,728 scenarios (records of 0 to 12,000
# bytes in three pieces, three start positions, reserves of 0, 1,000 and
# 3,072 bytes, four buffer sizes, four schedules) with the real reader and
# both wake handshakes; its limits at every bound. Both race under
# ThreadSanitizer, the reader with the writer and a mutator, the writer with
# a hostile consumer. The handshakes' fences are the litmus tests'
# (test/litmus/).
class LaneTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_LANE_SEED', '20261103'))
  LANE_SOURCE = 'liberx/erx_lane.c'
  # Every counter the exploration prints must be reached, or the model is
  # not exploring what it claims to.
  EXPLORE_COUNTERS = %w[scenarios states takes empty wraps partial header_only prod_waits prod_parks cons_parks
                        rings_prod rings_cons finished].freeze
  # One-line edits of the reader, each a failure the driver must catch.
  MUTANTS = {
    'wpos may run a grain past the area' => ['if (wpos - lane_grain_down(pos) > size)',
                                             'if (wpos - lane_grain_down(pos) > size + LANE_GRAIN)'],
    'wpos may fall behind what was read' => ['if (wpos < pos)', 'if (wpos < lane_grain_down(pos))'],
    'an exact need is not crossed' => ['return (before < waited && waited <= after);',
                                       'return (before < waited && waited < after);'],
    'rpos published inside a grain' => ['rpos = lane_grain_down(reader->pos);', 'rpos = reader->pos;'],
    'the copy ignores the wrap' => ['offset = pos & mask;', 'offset = pos & (mask | (mask + 1));'],
    'wake already crossed' => ['lane_grain_down(reader->pos) + 1);', 'lane_grain_down(reader->pos));'],
    'the copy ignores the buffer' => ['n = lane_min(lane_min(avail, reader->body_left), max);',
                                      'n = lane_min(lane_min(avail, reader->body_left), max + 64);'],
    'an unaligned wpos accepted' => ['if ((wpos & (LANE_GRAIN - 1)) != 0)', 'if (0)'],
    'a refused lane read again' => ["\t*part = (erx_lane_part_t){ 0 };\n\tif (reader->phase == ERX_LANE_REFUSED)\n",
                                    "\t*part = (erx_lane_part_t){ 0 };\n\tif (0)\n"],
    'a record of ERX_FRAME_MAX refused' => ['if (len > ERX_FRAME_MAX)', 'if (len >= ERX_FRAME_MAX)'],
    'a record past the last position accepted' => ["\t\treturn (ERX_LANE_RECORD_PAST_END);", "\t\treturn (ERX_LANE_SOUND);"],
    'padding left unread' => ['reader->pos = lane_grain_down(reader->pos + LANE_GRAIN - 1);', '(void)0;'],
    'rpos may run ahead of wpos' => ['if (rpos > pos)', 'if (rpos > pos + LANE_GRAIN)'],
    'rpos may move back' => ['if (rpos < last)', 'if (rpos < last && 0)'],
    'an unaligned rpos accepted' => ['if ((rpos & (LANE_GRAIN - 1)) != 0)', 'if (0 && (rpos & (LANE_GRAIN - 1)) != 0)'],
    'the reserve ignored' => ['return (room > reserve ? room - reserve : 0);', 'return (room > reserve ? room : 0);'],
    'need ignores the quarter' => ['wanted = lane_min(reserve + lane_min(rest, size / 4), size);',
                                   'wanted = lane_min(reserve + rest, size);'],
    'need from a stale wpos' => ['lane_need(writer->pos, writer->size,', 'lane_need(writer->pos + LANE_GRAIN, writer->size,'],
    'an armed put waits after progress' => ['if (st != ERX_LANE_PUT_SHORT || (part.written == 0 && !part.opened))',
                                            'if (1)'],
    'the gather ignores the offset' => ['(const unsigned char *)piece->base + offset, chunk);',
                                        '(const unsigned char *)piece->base, chunk);'],
    'padding left unwritten' => ['lane_write(writer, writer->pos + copied, zeros, n - copied);', '(void)zeros;'],
    'a refused writer writes again' => ["\t*put = (erx_lane_put_t){ 0 };\n\tif (writer->phase == ERX_LANE_REFUSED)\n",
                                        "\t*put = (erx_lane_put_t){ 0 };\n\tif (0)\n"],
    'another body continues a record' => ['if (total != writer->len || item->kind != writer->kind ||', 'if (0 ||'],
    'a body of ERX_FRAME_MAX refused' => ['if (item->iov[i].len > ERX_FRAME_MAX - total ||',
                                          'if (item->iov[i].len >= ERX_FRAME_MAX - total ||'],
    'a put past the last position accepted' => ['} else if (__builtin_add_overflow(writer->pos,',
                                                '} else if (0 && __builtin_add_overflow(writer->pos,'],
    'a stopped reader loads wpos again' => ["\tif (reader->stopped)\n\t\twpos = reader->stop_wpos;", "\tif (0)\n\t\twpos = reader->stop_wpos;"],
    'a stop that skips its check' => ["\tif (fault != ERX_LANE_SOUND) {\n\t\t(void)lane_refuse(reader, fault);", "\tif (0) {\n\t\t(void)lane_refuse(reader, fault);"],
    'a crossed wake not rung' => ['return (lane_crossed(published, writer->pos, wake));', 'return (false);']
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-lane-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported lane-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, LANE_SOURCE), name: 'lane', flags: @sanitizer_flags)
  end

  def test_every_interleaving_agrees_with_the_model
    counts = counters(run_mode(driver, 'explore').fetch('explore'))
    assert_equal EXPLORE_COUNTERS.sort, counts.keys.sort
    EXPLORE_COUNTERS.each { |name| assert_operator counts.fetch(name), :>, 0, "explore never reached #{name}" }
    assert_equal 207, counts.fetch('scenarios')
  end

  def test_a_record_cut_at_every_boundary_equals_it_whole
    assert_equal({ 'runs' => 972 }, counters(run_mode(driver, 'cuts').fetch('cuts')))
  end

  def test_positions_and_lengths_at_their_limits
    assert_equal({ 'cases' => 46 }, counters(run_mode(driver, 'limits').fetch('limits')))
  end

  def test_seeded_failures_are_caught
    MUTANTS.each do |name, (original, replacement)|
      mutant = build_driver(mutant_source(name, original, replacement), name: "mutant-#{slug(name)}", flags: [])
      caught = %w[limits wlimits explore cuts writer].any? do |mode|
        run_mode(mutant, mode)
        false
      rescue Erx::Error
        true
      end
      assert caught, "seeded failure not caught: #{name}"
    end
  end

  WRITER_COUNTERS = %w[scenarios puts armed short empty header_only closes prod_parks rings_prod rings_cons
                       cons_parks wraps reserve_held rearms].freeze

  def test_the_writer_agrees_with_the_model
    counts = counters(run_mode(driver, 'writer').fetch('writer'))
    assert_equal WRITER_COUNTERS.sort, counts.keys.sort
    WRITER_COUNTERS.each { |name| assert_operator counts.fetch(name), :>, 0, "writer never reached #{name}" }
    assert_equal 1728, counts.fetch('scenarios')
  end

  def test_the_writer_at_its_limits
    assert_equal({ 'cases' => 30 }, counters(run_mode(driver, 'wlimits').fetch('wlimits')))
  end

  # The writer puts while a hostile consumer publishes plausible positions,
  # then garbage: every put writes or waits until the garbage, which the
  # writer refuses once. ThreadSanitizer checks that no load of the writer
  # from the consumer's page races a store.
  def test_the_writer_against_a_hostile_consumer_under_thread_sanitizer
    race = counters(run_mode(tsan_driver, 'wrace', SEED.to_s, '100000').fetch('wrace'))
    assert_operator race.fetch('records'), :>, 0
    assert_operator race.fetch('puts'), :>=, 100_000
    assert_equal 1, race.fetch('malformed')
  end

  # The writer and the reader race over one lane, then, the writer stopped,
  # a third thread rewrites the producer's side. Before the rewriting
  # every byte read is the byte written; after it every part still adds up
  # to the header it was read under, rpos only grows by whole grains, and
  # a refusal is the reader's last word. ThreadSanitizer checks that no
  # load of the reader races a store.
  def test_concurrent_producer_and_mutator_under_thread_sanitizer
    race = counters(run_mode(tsan_driver, 'race', SEED.to_s, '100000').fetch('race'))
    assert_operator race.fetch('records'), :>, 0
    assert_operator race.fetch('takes'), :>=, 100_000
    # The mutation phase ran: the rewritten side was refused.
    assert_equal 1, race.fetch('malformed')
  end

  private

  def tsan_driver
    @tsan_driver ||= build_driver(File.join(@root, LANE_SOURCE), name: 'lane-tsan',
                                                           flags: %w[-fsanitize=thread -fno-omit-frame-pointer])
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(reader, name:, flags:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                 *flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), reader,
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'test/fixtures/lane_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def mutant_source(name, original, replacement)
    source = File.read(File.join(@root, LANE_SOURCE))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the lane"
    path = File.join(@directory, "mutant-#{slug(name)}.c")
    File.write(path, source.sub(original, replacement))
    path
  end

  def slug(name) = name.downcase.gsub(/[^a-z0-9]+/, '-')

  # The driver's summary lines by mode: "MODE: name=value ...".
  def run_mode(program, *arguments)
    record = @runner.run([program, *arguments], name: 'lane-driver', deadline: 300)
    File.read(record.fetch('log')).lines.filter_map do |line|
      match = /\A(?<mode>[a-z]+): (?<rest>.*)\z/.match(line.chomp)
      [match[:mode], match[:rest]] if match
    end.to_h
  end

  def counters(line) = line.split.to_h { |pair| pair.split('=', 2).then { |key, value| [key, Integer(value)] } }
end
