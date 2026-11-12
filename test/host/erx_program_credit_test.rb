# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# A program's credit and the shape reader that feeds it
# (otp/erts/emulator/sys/erxos/erx_program_core.c), through
# test/fixtures/erx_program_credit_driver.c under the address and undefined
# sanitizers. The model is docs/design-programs.md's "Credit": a reply slot is
# busy from the request delivered on it until the reply on it is taken, and every
# frame outside the credit, a request on a busy slot or any other shape, ends the
# program with SIGSYS. The credit is a protocol state machine, so it is checked
# exhaustively over a bounded model: every sequence of up to six frames and
# replies on three of the sixteen slots, one past the last and another shape
# agrees with the model, delivers at most one request per slot between replies
# on it, and refuses every frame outside the credit. Seeded failures of the core
# must each fail their check.
class ErxProgramCreditTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'otp/erts/emulator/sys/erxos/erx_program_core.c'
  SOURCES = %w[test/fixtures/erx_program_credit_driver.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
               kernel/crypto/blake3/blake3_portable.c].freeze
  INCLUDES = %w[include otp/erts/emulator/sys/erxos kernel/crypto kernel/crypto/blake3].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  SLOTS = 16
  # The bounded model: three slots, the first, the second and the last, one past the last,
  # and another shape.
  MODEL_SLOTS = [0, 1, 15].freeze
  INPUTS = [*MODEL_SLOTS.map { [:request, _1] }, [:request, SLOTS], [:other],
            *MODEL_SLOTS.map { [:reply, _1] }, [:reply, SLOTS]].freeze
  STATES = (0...(1 << MODEL_SLOTS.size)).map do |bits|
    MODEL_SLOTS.each_with_index.sum { |slot, i| bits[i].zero? ? 0 : 1 << slot }
  end.freeze
  LENGTH = 6

  # Records in ETF and the shape the reader must give each.
  def self.atom(name) = [119, name.bytesize].pack('CC') + name
  def self.small(value) = [97, value].pack('CC')
  def self.tuple(*elements) = [104, elements.size].pack('CC') + elements.join
  TAG = atom('erx_prog')
  BODY = atom('getpid')
  SHAPES = {
    tuple(TAG, small(1), small(0), BODY) => 'request 0',
    tuple(TAG, small(1), small(15), BODY) => 'request 15',
    # A large tuple, the slot as a 32-bit integer, the body a container.
    ([105, 4].pack('CN') + TAG + small(1) + [98, 7].pack('CN') + tuple(BODY, BODY)) => 'request 7',
    # A list of no element around the version is the version itself.
    tuple(TAG, [108, 0].pack('CN') + small(1), small(3), BODY) => 'request 3',
    tuple(TAG, small(1), small(16), BODY) => 'other',
    tuple(TAG, small(1), [98, -1].pack('Cl>'), BODY) => 'other',
    tuple(TAG, tuple(small(1)), small(3), BODY) => 'other',
    tuple(TAG, small(1), small(3)) => 'other',
    tuple(TAG, small(1), small(3), BODY, BODY) => 'other',
    tuple(atom('closed'), small(1), small(3), BODY) => 'other',
    tuple(atom('erx_pro'), small(1), small(3), BODY) => 'other',
    tuple(TAG, small(1), atom('a'), BODY) => 'other',
    [108, 1].pack('CN') + TAG + "\x6a".b => 'other',
    tuple(TAG, small(1), small(3), BODY)[0, 6] => 'other'
  }.transform_keys { "\x83".b + _1 }.merge("\x83".b => 'other', ''.b => 'other',
                                            tuple(TAG, small(1), small(0), BODY) => 'other').freeze

  def test_the_shape_reader_names_requests_and_their_slots_only
    answers = drive(build(File.join(ROOT, CORE)), SHAPES.keys.map { "shape #{_1.unpack1('H*')}" })
    SHAPES.zip(answers).each { |(bytes, want), got| assert_equal want, got, bytes.unpack1('H*') }
  end

  def test_every_sequence_of_the_bounded_model_keeps_the_credit
    table = transitions(build(File.join(ROOT, CORE)))
    assert_empty mismatches(table)
    assert_empty broken_sequences(table)
  end

  # Every slot, not only the model's three, is busy alone and freed alone.
  def test_every_slot_is_one_credit
    binary = build(File.join(ROOT, CORE))
    full = (1 << SLOTS) - 1
    lines = (0...SLOTS).flat_map do |slot|
      ["step 0 request #{slot}", "step #{1 << slot} request #{slot}", "step #{full} reply #{slot}",
       "step #{full ^ (1 << slot)} request #{slot}"]
    end
    want = (0...SLOTS).flat_map do |slot|
      ["deliver #{1 << slot}", "refuse #{1 << slot}", "replied #{full ^ (1 << slot)}", "deliver #{full}"]
    end
    assert_equal want, drive(binary, lines)
  end

  SEEDS = {
    'a delivered request leaves its slot free' => ["\tcredit->busy |= bit;\n", ''],
    'another shape is delivered' => ['frame.kind != ERX_PROGRAM_FRAME_REQUEST || ', ''],
    'a reply leaves its slot busy' => ["\tcredit->busy &= (uint16_t)~bit;\n", ''],
    'a reply on a free slot is taken' => ["\tif ((credit->busy & bit) == 0)\n\t\treturn (false);\n", '']
  }.freeze

  def test_seeded_failures_of_the_credit_are_caught
    source = File.read(File.join(ROOT, CORE))
    SEEDS.each do |name, (from, to)|
      assert_includes source, from, name
      table = transitions(build(write_source(name, source.sub(from, to))))
      refute (mismatches(table) + broken_sequences(table)).empty?, "seed not caught: #{name}"
    end
  end

  def test_a_seeded_slot_bound_in_the_shape_reader_is_caught
    source = File.read(File.join(ROOT, CORE))
    from = 'ERX_PROGRAM_SLOTS - 1, &slot'
    assert_includes source, from
    binary = build(write_source('slot-bound', source.sub(from, 'ERX_PROGRAM_SLOTS, &slot')))
    answers = drive(binary, SHAPES.keys.map { "shape #{_1.unpack1('H*')}" })
    refute_equal SHAPES.values, answers
  end

  private

  # The model's answer to input from busy.
  def model(busy, input)
    case input
    in [:request, slot] if slot < SLOTS && busy[slot].zero? then ['deliver', busy | (1 << slot)]
    in [:request, _] | [:other] then ['refuse', busy]
    in [:reply, slot] if slot < SLOTS && busy[slot] == 1 then ['replied', busy & ~(1 << slot)]
    in [:reply, _] then ['unreplied', busy]
    end
  end

  def transitions(binary)
    keys = STATES.product(INPUTS)
    lines = keys.map { |busy, input| "step #{busy} #{input.join(' ')}" }
    keys.zip(drive(binary, lines)).to_h do |key, answer|
      verdict, busy = answer.split
      [key, [verdict, Integer(busy)]]
    end
  end

  def mismatches(table)
    table.filter_map do |(busy, input), got|
      want = model(busy, input)
      "#{busy} #{input.inspect}: #{got.inspect}, want #{want.inspect}" unless got == want
    end
  end

  # Walks every sequence of up to LENGTH inputs from no slot busy through the core's own
  # table: no slot ever carries two delivered requests between replies on it, and every frame
  # outside the credit is refused.
  def broken_sequences(table)
    (1..LENGTH).map { INPUTS.repeated_permutation(_1) }.reduce(:+).lazy.filter_map do |sequence|
      problem = sequence_problem(table, sequence)
      "#{sequence.inspect}: #{problem}" if problem
    end.first(5)
  end

  def sequence_problem(table, sequence)
    outstanding = Hash.new(0)
    busy = 0
    sequence.each do |input|
      verdict, busy = table.fetch([busy, input]) { return "no row for #{busy} #{input.inspect}" }
      kind, slot = input
      within = kind == :request && slot < SLOTS && outstanding[slot].zero?
      return "#{input.inspect} outside the credit was delivered" if verdict == 'deliver' && !within
      return "#{input.inspect} within the credit was refused" if kind == :request && within && verdict != 'deliver'

      outstanding[slot] += 1 if verdict == 'deliver'
      outstanding[slot] -= 1 if verdict == 'replied'
      return "slot #{slot} has #{outstanding[slot]} requests outstanding" unless outstanding[slot].between?(0, 1)
    end
    nil
  end

  def write_source(name, text)
    path = File.join(directory, "core-#{name.tr(' ', '-')}.c")
    File.write(path, text)
    path
  end

  def directory = @directory ||= Dir.mktmpdir('erx-program-credit-')

  def build(source)
    binary = File.join(directory, File.basename(source, '.c'))
    includes = INCLUDES.flat_map { ['-I', File.join(ROOT, _1)] }
    log, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT), *includes,
                                  source, *SOURCES.map { File.join(ROOT, _1) }, '-o', binary, stdin_data: '')
    assert status.success?, log
    binary
  end

  # The driver's answers, one per line. Anything but a clean exit, a sanitizer's report
  # included, is a broken run.
  def drive(binary, lines)
    log, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary,
                                  stdin_data: lines.map { "#{_1}\n" }.join)
    assert status.success?, log
    log.lines(chomp: true).tap { assert_equal lines.size, _1.size, log }
  end
end
