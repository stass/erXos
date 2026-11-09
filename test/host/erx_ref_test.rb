# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# Reference identities (docs/design-runtime.md, "Unguessable references") in their C core,
# otp/erts/emulator/sys/erxos/erx_ref.c over the imported ctaes, driven by
# test/fixtures/erx_ref_driver.c under the address and undefined sanitizers, and its threads
# under the thread sanitizer.
#
# The threat: a reference names a reply or an alias, so a party that is not meant to hold
# one (a process of another domain, a node an exposed domain talks to) gains by naming a
# live reference it was never handed, for example to forge the reply to a pending call.
# Stock ERTS counts references, so one observed reference gives away its neighbours. Here a
# reference is AES-128 under a secret key of its domain's runtime, so guessing is bounded
# by the cipher. The tests hold the core to what that argument needs:
# * the permutation is AES-128: FIPS 197's examples, and the host's OpenSSL over random
#   keys and blocks;
# * an identity is exactly the permutation of the ABI's block, source and counter
#   little-endian, which the OpenSSL model checks for every identity the tests make; that
#   exact agreement is the evidence that nothing of the counter shows through, and the
#   check that consecutive identities differ in about half their bits only guards against
#   the permutation being skipped;
# * no identity repeats: counters carry, are refused at their last value and never wrap,
#   a source never opened makes nothing, ordinals are refused past the last and never
#   reused, and threads opening sources and making references concurrently in a narrowed
#   build reach every exhaustion with every identity distinct and each the model's;
# * the runtime erases the key bytes it was given;
# * seeded faults (no permutation, a counter not advanced, a dropped borrow, a spent source
#   still making, a source opened with one value too many, one ordinal too many) each fail
#   the tests named for them.
class ErxRefTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SYS = File.join(ROOT, 'otp/erts/emulator/sys/erxos')
  SOURCES = [File.join(SYS, 'erx_ref.c'), File.join(ROOT, 'ctaes/ctaes.c')].freeze
  DRIVER = File.join(ROOT, 'test/fixtures/erx_ref_driver.c')
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-fno-omit-frame-pointer',
           '-pthread'].freeze
  SANITIZERS = { memory: ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'],
                 thread: ['-fsanitize=thread'] }.freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  SEED = 17
  U32 = 0xffff_ffff
  U64 = 0xffff_ffff_ffff_ffff
  # The narrowed build of the threads tests: 8 ordinals, and 2^9 - 1 references a source.
  NARROW = { source_bits: 3, counter_bits: 9 }.freeze
  THREADS = 12

  # FIPS 197 Appendix B and Appendix C.1: key, input, output.
  FIPS_197 = [%w[2b7e151628aed2a6abf7158809cf4f3c 3243f6a8885a308d313198a2e0370734 3925841d02dc09fbdc118597196a0b32],
              %w[000102030405060708090a0b0c0d0e0f 00112233445566778899aabbccddeeff 69c4e0d86a7b0430d8cdb78070b4c55a]].freeze

  # A source's starting point for the identities test: its ordinal, its next counter value
  # high:low, and how many references it is asked for.
  Start = Data.define(:ordinal, :high, :low, :count)
  STARTS = {
    'the first values' => Start.new(ordinal: 7, high: 0, low: 0, count: 3),
    'the low word carrying into the high' => Start.new(ordinal: U32, high: 0, low: U64 - 1, count: 3),
    'a middle value' => Start.new(ordinal: 12, high: 5, low: 9, count: 2),
    'the last values, then refused' => Start.new(ordinal: 3, high: U32, low: U64 - 2, count: 4),
    'already spent' => Start.new(ordinal: 1, high: U32, low: U64, count: 2)
  }.freeze

  IDENTITIES = :test_identities_are_the_permuted_block_and_counters_carry_and_stop
  CONCURRENT = :test_concurrent_sources_reach_every_exhaustion_without_a_repeat
  CHECKS = %i[test_permutation_is_aes_128 test_identities_are_the_permuted_block_and_counters_carry_and_stop
              test_an_unopened_source_makes_nothing test_ordinals_are_refused_past_the_last
              test_consecutive_identities_differ_in_half_their_bits
              test_concurrent_sources_reach_every_exhaustion_without_a_repeat
              test_the_source_of_an_identity_is_deciphered_and_bounded].freeze
  # Each fault with the checks that exist to catch it; the mutant test also requires it to build.
  Mutant = Data.define(:original, :replacement, :caught_by)
  MUTANTS = {
    'no permutation' => Mutant.new('erx_ref_permute(runtime, block, identity);',
                                 '(void)runtime; __builtin_memcpy(identity, block, sizeof(block));',
                                 [IDENTITIES, :test_consecutive_identities_differ_in_half_their_bits]),
    'counter not advanced' => Mutant.new("\t\tsource->remaining_low--;", "\t\t(void)0;", [IDENTITIES, CONCURRENT]),
    'borrow dropped' => Mutant.new('source->remaining_high--;', '(void)0;', [IDENTITIES]),
    'spent source still makes' => Mutant.new('if (source_spent(source))', 'if (0 && source_spent(source))',
                                           [IDENTITIES, :test_an_unopened_source_makes_nothing, CONCURRENT]),
    'one value too many' => Mutant.new('source->remaining_low = ERX_REF_COUNTER_LAST_LOW;',
                                    'source->remaining_low = ERX_REF_COUNTER_LAST_LOW + 1;', [CONCURRENT]),
    'unbounded source_of' => Mutant.new('if (source >= atomic_load_explicit(&runtime->taken, memory_order_relaxed))',
                                        'if (false)', [:test_the_source_of_an_identity_is_deciphered_and_bounded]),
    'one ordinal too many' => Mutant.new('if (taken >= SOURCE_ORDINALS)', 'if (taken > SOURCE_ORDINALS)',
                                       [:test_ordinals_are_refused_past_the_last, CONCURRENT])
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-ref-')
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def test_permutation_is_aes_128
    random = Random.new(SEED)
    cases = FIPS_197 + Array.new(200) do
      key = random.bytes(16)
      block = random.bytes(16)
      [hex(key), hex(block), hex(aes(key, block))]
    end
    answers = run_driver(build, cases.map { |key, input, _| "permute #{key} #{input}" })
    assert_equal(cases.map { |_, _, output| "permute #{output}" }, answers)
  end

  def test_identities_are_the_permuted_block_and_counters_carry_and_stop
    key = Random.new(SEED).bytes(16)
    program = build
    STARTS.each do |name, start|
      answers = run_driver(program, ["make #{hex(key)} #{start.ordinal} #{start.high} #{start.low} #{start.count}"])
      assert_equal model_run(key, start), answers, name
    end
  end

  def test_an_unopened_source_makes_nothing
    assert_equal ['ref limit'], run_driver(build, ["fresh #{hex(Random.new(SEED).bytes(16))}"])
  end

  def test_ordinals_are_refused_past_the_last
    answers = run_driver(build, ["sources #{(1 << 32) - 2} 4", 'sources 0 2'])
    assert_equal ["source #{U32 - 1}", "source #{U32}", 'source limit', 'source limit', 'source 0', 'source 1'], answers
  end

  # A deciphered identity names its source only within what the runtime handed out: the
  # ordinals taken, and counter values below the last. Forged words, a block of an ordinal
  # not yet taken or of the last counter value, are refused.
  def test_the_source_of_an_identity_is_deciphered_and_bounded
    key = hex(Random.new(SEED).bytes(16))
    answers = run_driver(build, ["source_of #{key} 3 2 7 9", "source_of #{key} 3 0 0 0",
                                 "source_of #{key} 3 3 0 0", "source_of #{key} 3 #{U32} 0 0",
                                 "source_of #{key} 3 1 #{U32} #{U64}", "source_of #{key} 3 1 #{U32} #{U64 - 1}"])
    assert_equal ["source_of 2", "source_of 0", "source_of refused", "source_of refused", "source_of refused",
                  "source_of 1"], answers
  end

  def test_consecutive_identities_differ_in_half_their_bits
    key = Random.new(SEED).bytes(16)
    answers = run_driver(build, ["make #{hex(key)} 0 0 0 4096"])
    identities = answers.grep(/\Aref [0-9a-f]/).map { |line| Integer(line.delete_prefix('ref ').delete(' '), 16) }
    assert_equal 4096, identities.uniq.size
    distances = identities.each_cons(2).map { |a, b| (a ^ b).to_s(2).count('1') }
    assert_in_delta 64.0, distances.sum.fdiv(distances.size), 1.0
    assert_operator distances.min, :>, 32
    other = run_driver(build, ["make #{hex(Random.new(SEED + 1).bytes(16))} 0 0 0 4096"])
    assert_empty answers.grep(/\Aref [0-9a-f]/) & other, 'another key shares no identity'
  end

  def test_concurrent_sources_reach_every_exhaustion_without_a_repeat
    key = Random.new(SEED).bytes(16)
    answers = run_driver(build(**NARROW), ["threads #{hex(key)} #{THREADS}"])
    ordinals = 1 << NARROW.fetch(:source_bits)
    per_source = (1 << NARROW.fetch(:counter_bits)) - 1
    assert_equal "threads #{ordinals} #{THREADS - ordinals}", answers.first
    made = answers.drop(1)
    assert_equal ordinals * per_source, made.size
    assert_equal made.size, made.uniq.size, 'no identity repeats'
    expected = (0...ordinals).flat_map do |ordinal|
      (0...per_source).map { |counter| "id #{ordinal} #{words(model_identity(key, ordinal, 0, counter))}" }
    end
    assert_equal expected.sort, made.sort
  end

  # The same threads under the thread sanitizer, which fails the run on a data race in the
  # opening of sources that the results alone might not show.
  def test_concurrent_sources_open_without_a_race
    key = Random.new(SEED).bytes(16)
    answers = run_driver(build(**NARROW, sanitizer: :thread), ["threads #{hex(key)} #{THREADS}"])
    assert_equal "threads #{1 << NARROW.fetch(:source_bits)} #{THREADS - (1 << NARROW.fetch(:source_bits))}",
                 answers.first
  end

  def test_every_seeded_fault_fails
    MUTANTS.each do |name, mutant|
      source = File.read(SOURCES.first)
      assert_equal 1, source.scan(mutant.original).size, "mutant #{name} names one site"
      path = File.join(@directory, "erx_ref_#{name.tr(' ', '_')}.c")
      File.write(path, source.sub(mutant.original, mutant.replacement))
      assert_equal mutant.caught_by.sort, (failing_checks(path) & mutant.caught_by).sort, "mutant #{name}"
    end
  end

  private

  # The checks the core at path fails. It must build, so a fault cannot pass for caught by
  # breaking the build.
  def failing_checks(path)
    @core = path
    build
    build(**NARROW)
    CHECKS.reject do |check|
      send(check)
      true
    rescue Minitest::Assertion
      false
    end
  ensure
    @core = nil
  end

  def build(source_bits: nil, counter_bits: nil, sanitizer: :memory)
    widths = { 'ERX_REF_SOURCE_BITS' => source_bits, 'ERX_REF_COUNTER_BITS' => counter_bits }
             .compact.map { |name, value| "-D#{name}=#{value}" }
    program = File.join(@directory, "driver-#{sanitizer}-#{source_bits}-#{counter_bits}-#{File.basename(core, '.c')}")
    return program if File.exist?(program)

    output, status = Open3.capture2e(COMPILER, *FLAGS, *SANITIZERS.fetch(sanitizer), *widths, '-I', SYS, '-I', ROOT,
                                     '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                                     DRIVER, core, SOURCES.last, '-o', program, stdin_data: '')
    assert status.success?, output
    program
  end

  def core = @core || SOURCES.first

  def run_driver(program, requests)
    output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), 'gtimeout', '-k', '10',
                                     '120', program, stdin_data: requests.map { |request| "#{request}\n" }.join)
    assert status.success?, output
    output.lines(chomp: true)
  end

  # What the driver prints for start: each reference the model's, refused from the last
  # value on, then the next value left.
  def model_run(key, start)
    high = start.high
    low = start.low
    lines = Array.new(start.count) do
      next 'ref limit' if [high, low] == [U32, U64]

      identity = model_identity(key, start.ordinal, high, low)
      high, low = low == U64 ? [high + 1, 0] : [high, low + 1]
      "ref #{words(identity)}"
    end
    lines << "state #{high} #{low}"
  end

  # The ABI's erx_ref_block, every field little-endian, enciphered; its four words.
  def model_identity(key, ordinal, high, low)
    block = [ordinal, low & U32, low >> 32, high].pack('V4')
    aes(key, block).unpack('V4')
  end

  def words(identity) = identity.map { |word| format('%08x', word) }.join(' ')

  def aes(key, block)
    cipher = OpenSSL::Cipher.new('aes-128-ecb').encrypt
    cipher.key = key
    cipher.padding = 0
    cipher.update(block) + cipher.final
  end

  def hex(bytes) = bytes.unpack1('H*')
end
