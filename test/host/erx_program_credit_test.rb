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
# busy from the request delivered on it until the reply on it is taken; a notice
# is due once for each grant of a frame the driver took to write, and a delivered
# notice spends its grant; every frame outside the credit, a request on a busy
# slot, a notice not due or any other shape, ends the program with SIGSYS; and a
# send is taken only when its reply slot is busy, its grants are well formed and
# the due notices stay within their bounds. The credit is a protocol state
# machine, so it is checked exhaustively over a bounded model: every state
# reachable from the empty credit with three of the sixteen slots, two {closed}
# keys and one {drained} key, under bounds of two {closed} and one {drained},
# agrees with the model on every input; and every sequence of up to LENGTH
# inputs delivers at most one request per slot between replies on it and at
# most one notice per grant. Seeded failures of the core must each fail their
# check.
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
  # The fixture's bounds (CLOSED_MAX and DRAINED_MAX), by a key's first letter.
  BOUNDS = { 'c' => 2, 'd' => 1 }.freeze
  # The bounded model: three slots, the first, the second and the last, one past the last;
  # two {closed} keys and a {drained} key the sends may grant, and one never granted.
  MODEL_SLOTS = [0, 1, 15].freeze
  KEYS = %w[c1.1 c1.2 d1.1.2].freeze
  INPUTS = [*MODEL_SLOTS.map { "request #{_1}" }, "request #{SLOTS}", 'other',
            *KEYS.map { "notice #{_1}" }, 'notice c2.2',
            *MODEL_SLOTS.map { "send #{_1} -" }, "send #{SLOTS} -", 'send none -',
            *KEYS.map { "send none #{_1}" }, 'send none c1.1,c1.1', 'send none c1.1,c1.2,c1.2',
            'send 0 c1.2', 'send none c0.1', 'send none d1.1.0'].freeze
  LENGTH = 4

  # Records in ETF and the shape the reader must give each.
  def self.atom(name) = [119, name.bytesize].pack('CC') + name
  def self.small(value) = [97, value].pack('CC')
  def self.int(value) = [98, value].pack('Cl>')
  def self.big(*bytes) = [110, bytes.size, 0, *bytes].pack('C*')
  def self.tuple(*elements) = [104, elements.size].pack('CC') + elements.join
  TAG = atom('erx_prog')
  BODY = atom('getpid')
  CLOSED = atom('closed')
  DRAINED = atom('drained')
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
    tuple(TAG, small(1), small(3), BODY, BODY) => 'other',
    tuple(atom('closed'), small(1), small(3), BODY) => 'other',
    tuple(atom('erx_pro'), small(1), small(3), BODY) => 'other',
    tuple(TAG, small(1), atom('a'), BODY) => 'other',
    [108, 1].pack('CN') + TAG + "\x6a".b => 'other',
    tuple(TAG, small(1), small(3), BODY)[0, 6] => 'other',
    # Notices: each number from 1 to 2^32 - 1, the largest a bignum.
    tuple(TAG, small(1), tuple(CLOSED, small(1), small(2))) => 'notice c1.2',
    tuple(TAG, small(1), tuple(DRAINED, small(3), int(70_000), big(255, 255, 255, 255))) =>
      'notice d3.70000.4294967295',
    tuple(TAG, small(1), tuple(CLOSED, small(1), big(0, 0, 0, 0, 1))) => 'other',
    tuple(TAG, small(1), tuple(CLOSED, small(0), small(2))) => 'other',
    tuple(TAG, small(1), tuple(CLOSED, small(1), int(-1))) => 'other',
    tuple(TAG, small(1), tuple(CLOSED, small(1), small(2), small(3))) => 'other',
    tuple(TAG, small(1), tuple(DRAINED, small(1), small(2))) => 'other',
    tuple(TAG, small(1), tuple(atom('closes'), small(1), small(2))) => 'other',
    tuple(TAG, small(1), tuple(CLOSED, small(1), atom('a'))) => 'other',
    tuple(TAG, small(1), small(3)) => 'other',
    tuple(TAG, small(1), tuple(CLOSED, small(1), small(2)))[0, 12] => 'other'
  }.transform_keys { "\x83".b + _1 }.merge("\x83".b => 'other', ''.b => 'other',
                                            tuple(TAG, small(1), small(0), BODY) => 'other').freeze

  def test_the_shape_reader_names_requests_notices_and_their_keys_only
    answers = drive(build(File.join(ROOT, CORE)), SHAPES.keys.map { "shape #{_1.unpack1('H*')}" })
    SHAPES.zip(answers).each { |(bytes, want), got| assert_equal want, got, bytes.unpack1('H*') }
  end

  def test_every_reachable_state_of_the_bounded_model_keeps_the_credit
    table = transitions(build(File.join(ROOT, CORE)))
    assert_empty mismatches(table)
    assert_empty broken_sequences(table)
  end

  # Every slot, not only the model's three, is busy alone and freed alone.
  def test_every_slot_is_one_credit
    binary = build(File.join(ROOT, CORE))
    full = (1 << SLOTS) - 1
    lines = (0...SLOTS).flat_map do |slot|
      ["step 0 - request #{slot}", "step #{1 << slot} - request #{slot}", "step #{full} - send #{slot} -",
       "step #{full ^ (1 << slot)} - request #{slot}"]
    end
    want = (0...SLOTS).flat_map do |slot|
      ["deliver #{1 << slot} -", "refuse #{1 << slot} -", "admitted #{full ^ (1 << slot)} -", "deliver #{full} -"]
    end
    assert_equal want, drive(binary, lines)
  end

  SEEDS = {
    'a delivered request leaves its slot free' => ["\t\tcredit->busy |= bit;\n", ''],
    'another shape is delivered' => ["\t\tbreak;\n\t}\n\treturn (ERX_PROGRAM_REFUSE);\n}",
                                     "\t\tbreak;\n\t}\n\treturn (ERX_PROGRAM_DELIVER);\n}"],
    'a reply leaves its slot busy' => ["\t\tcredit->busy &= (uint16_t)~(1u << send->reply);\n", ''],
    'a reply on a free slot is taken' => [' || (credit->busy & (1u << send->reply)) == 0', ''],
    'a delivered notice leaves its grant due' => ["\t\tif (notice.kind == ERX_PROGRAM_NOTICE_CLOSED)\n" \
                                                  "\t\t\tcredit->closed--;\n\t\telse\n\t\t\tcredit->drained--;\n", ''],
    'a grant passes its bound' => ['closed <= credit->closed_max - credit->closed', 'closed <= credit->closed_max'],
    'a grant with a zero number is kept' => ["\tif (grant.pipe == 0 || grant.end == 0)\n\t\treturn (false);\n", '']
  }.freeze

  def test_seeded_failures_of_the_credit_are_caught
    source = File.read(File.join(ROOT, CORE))
    SEEDS.each do |name, (from, to)|
      assert_includes source, from, name
      binary = build(write_source(name, source.sub(from, to)))
      assert caught?(binary), "seed not caught: #{name}"
    end
  end

  # Whether the core in binary breaks the model or the sequences, or the run itself: a seed
  # that lets the due keys pass their storage is a sanitizer's report.
  def caught?(binary)
    table = transitions(binary)
    !(mismatches(table) + broken_sequences(table)).empty?
  rescue Minitest::Assertion
    true
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

  # A state: the busy mask and the due keys, sorted, as the fixture prints them.
  State = Data.define(:busy, :due) do
    def to_s = "#{busy} #{due.empty? ? '-' : due.join(',')}"
  end

  def keys_of(text) = text == '-' ? [] : text.split(',')

  def valid_key?(key)
    numbers = key[1..].split('.').map { Integer(_1) }
    numbers.size == (key.start_with?('c') ? 2 : 3) && numbers.all?(&:positive?)
  end

  def admits?(state, reply, grants)
    return false unless reply == 'none' || (Integer(reply) < SLOTS && state.busy[Integer(reply)] == 1)
    return false unless grants.all? { valid_key?(_1) }

    BOUNDS.all? { |kind, bound| (state.due + grants).count { _1.start_with?(kind) } <= bound }
  end

  def without_one(due, key) = due.dup.tap { _1.delete_at(_1.index(key)) }

  # The model's answer to input from state: the verdict and the next state.
  def model(state, input)
    case input.split
    in ['request', slot] if Integer(slot) < SLOTS && state.busy[Integer(slot)].zero?
      ['deliver', state.with(busy: state.busy | (1 << Integer(slot)))]
    in ['request', _] | ['other'] then ['refuse', state]
    in ['notice', key] if state.due.include?(key) then ['deliver', state.with(due: without_one(state.due, key))]
    in ['notice', _] then ['refuse', state]
    in ['send', reply, list]
      grants = keys_of(list)
      return ['refused', state] unless admits?(state, reply, grants)

      busy = reply == 'none' ? state.busy : state.busy & ~(1 << Integer(reply))
      ['admitted', State.new(busy: busy, due: (state.due + grants).sort)]
    end
  end

  # The core's table over every state the model reaches from the empty credit, found
  # breadth first: each round asks the fixture for the new states' rows.
  def transitions(binary)
    table = {}
    frontier = [State.new(busy: 0, due: [])]
    until frontier.empty?
      keys = frontier.product(INPUTS)
      answers = drive(binary, keys.map { |state, input| "step #{state} #{input}" })
      keys.zip(answers).each { |key, answer| table[key] = parse(answer) }
      frontier = keys.map { model(*_1).last }.uniq.reject { |state| table.key?([state, INPUTS.first]) }
    end
    table
  end

  def parse(answer)
    verdict, busy, due = answer.split
    [verdict, State.new(busy: Integer(busy), due: keys_of(due))]
  end

  def mismatches(table)
    table.filter_map do |(state, input), got|
      want = model(state, input)
      "#{state} #{input}: #{got.inspect}, want #{want.inspect}" unless got == want
    end
  end

  # Walks every sequence of up to LENGTH inputs from the empty credit through the core's own
  # table: no slot ever carries two delivered requests between replies on it, no notice is
  # delivered more often than sends granted it, and a request within the credit is delivered.
  def broken_sequences(table)
    (1..LENGTH).lazy.flat_map { INPUTS.repeated_permutation(_1).lazy }.filter_map do |sequence|
      problem = sequence_problem(table, sequence)
      "#{sequence.inspect}: #{problem}" if problem
    end.first(5)
  end

  def sequence_problem(table, sequence)
    outstanding = Hash.new(0)
    granted = Hash.new(0)
    state = State.new(busy: 0, due: [])
    sequence.each do |input|
      verdict, state = table.fetch([state, input]) { return "no row for #{state} #{input}" }
      problem = step_problem(input.split, verdict, outstanding, granted)
      return problem if problem
    end
    nil
  end

  def step_problem(input, verdict, outstanding, granted)
    case input
    in ['request', slot]
      within = Integer(slot) < SLOTS && outstanding[slot].zero?
      return "#{input.join(' ')} outside the credit was delivered" if verdict == 'deliver' && !within
      return "#{input.join(' ')} within the credit was refused" if within && verdict != 'deliver'

      outstanding[slot] += 1 if verdict == 'deliver'
    in ['notice', key]
      return "#{key} delivered beyond its grants" if verdict == 'deliver' && (granted[key] -= 1).negative?
    in ['send', reply, list] if verdict == 'admitted'
      return "a reply on free slot #{reply} was taken" if reply != 'none' && (outstanding[reply] -= 1).negative?

      keys_of(list).each { granted[_1] += 1 }
    in _ then nil
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
