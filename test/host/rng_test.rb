# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require_relative '../fixtures/crypto_fixture'

# Judges the kernel's entropy generator, kernel/core/rng.c, against
# CryptoFixture::Generator, a model written from the design's statements
# on OpenSSL's ChaCha20 and Ruby's SHA-256. Seeded random sequences of
# inits, reads, mixes and clears must agree with the model in every output,
# every key and every refusal. Hand cases pin the refusals of a generator
# nobody seeded, the read bound, the first key against RFC 8439's published
# zero-key block, the fast key erasure (a read's new key never appears in
# what it returned, and every read moves the key) and the mixing rule. The
# driver stops if a spent digest is left unerased. Seeded one-line mutants
# of each rule must each fail.
class RngTest < Minitest::Test
  F = CryptoFixture
  SEED = 57
  # RFC 8439, A.1, test vector 1: the first 32 bytes of the zero key's
  # block 0.
  ZERO_KEY_BLOCK0 = '76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7'

  def setup
    @driver = F::Driver.new(name: 'rng')
  end

  def teardown
    @driver.remove if passed?
  end

  def test_random_sequences_agree_with_the_model
    random = Random.new(SEED)
    sequences = Array.new(80) do
      Array.new(random.rand(1..12)) do
        case random.rand(12)
        when 0..4 then [:read, [0, 1, 31, 32, 33, 63, 64, 65, 255, 256, 257, random.rand(0..300)].sample(random: random)]
        when 5..7 then [:mix, random.bytes(random.rand(0..300))]
        when 8..10 then [:init, random.bytes(random.rand(0..64))]
        else [:clear]
        end
      end
    end
    answers = @driver.ask(sequences.map { |ops| request(ops) })
    sequences.zip(answers).each do |ops, answer|
      assert_equal expected(ops), answer, "operations #{ops.map(&:first).inspect}"
    end
  end

  def test_a_generator_nobody_seeded_or_one_retired_refuses_everything
    zero = [F.hex(F::ZERO_KEY), '0']
    answers = parse(@driver.ask(['rng r:32 r:0 m:00 i:00 r:32 c r:0 m:01']).first)
    assert_equal [[:refused, *zero], [:refused, *zero], [:mix_refused, *zero]], answers[0, 3]
    assert_equal '1', answers[3].last
    assert_equal :read, answers[4].first
    assert_equal [[:clear, *zero], [:refused, *zero], [:mix_refused, *zero]], answers[5, 3]
  end

  def test_init_spends_the_zero_key_on_the_seeds_digest
    seed = 'seed'.b
    answer = parse(@driver.ask(["rng i:#{F.hex(seed)}"]).first)
    expected = F.unhex(ZERO_KEY_BLOCK0).bytes.zip(F.sha256(seed).bytes).map { |a, b| a ^ b }.pack('C*')
    assert_equal [[:init, F.hex(expected), '1']], answer
    assert_equal ZERO_KEY_BLOCK0, F.hex(F.chacha20(key: F::ZERO_KEY, counter: 0, nonce: F::ZERO_NONCE,
                                                   data: "\0".b * 32))
  end

  def test_reads_up_to_the_bound_are_served_and_longer_ones_change_nothing
    answers = parse(@driver.ask(['rng i:00 r:256 r:257 r:4096 r:256']).first).drop(1)
    assert_equal 256, F.unhex(answers[0][1]).bytesize
    assert_equal [:refused, answers[0][2], '1'], answers[1]
    assert_equal [:refused, answers[0][2], '1'], answers[2]
    assert_equal :read, answers[3][0]
    refute_equal answers[0][2], answers[3][2]
  end

  def test_a_read_never_returns_its_new_key_and_always_moves_it
    answers = parse(@driver.ask(['rng i:00 r:256 r:256 r:0 r:0 r:1']).first).drop(1)
    keys = answers.map { |answer| answer[2] }
    assert_equal keys.uniq, keys, 'every read, an empty one included, leaves a new key'
    answers.each do |_kind, output, key|
      next if output == '-'

      refute_includes F.unhex(output), F.unhex(key), 'a read returned the key it left'
    end
    outputs = answers.map { |answer| F.unhex(answer[1]) }.reject(&:empty?)
    assert_empty outputs[0].bytes.each_slice(32).to_a & outputs[1].bytes.each_slice(32).to_a,
                 'two reads returned the same stream'
  end

  def test_mixing_xors_the_digest_into_block_zero_whatever_the_bytes
    message = 'chosen by the mixer'.b
    answers = @driver.ask(["rng i: m:#{F.hex(message)}", 'rng i: m:', "rng i:01 m:#{F.hex(message)}"])
                     .map { |line| parse(line) }
    first = F.unhex(answers[0][0][1])
    block0 = F.chacha20(key: first, counter: 0, nonce: F::ZERO_NONCE, data: "\0".b * 32)
    expected = block0.bytes.zip(F.sha256(message).bytes).map { |a, b| a ^ b }.pack('C*')
    assert_equal [:mix, F.hex(expected), '1'], answers[0][1]
    # Mixing nothing still spends the key; the same bytes from another key
    # give another key; the key is never the bare digest.
    refute_equal answers[1][0][1], answers[1][1][1]
    refute_equal answers[0][1][1], answers[2][1][1]
    refute_equal F.hex(F.sha256(message)), answers[0][1][1]
  end

  def test_clear_erases_the_key
    answers = parse(@driver.ask(['rng i:0102 r:8 c']).first)
    assert_equal [:clear, F.hex(F::ZERO_KEY), '0'], answers[2]
  end

  def test_mutants_fail
    mutants = {
      'output from block 0' => ['#define ERX_RNG_OUTPUT_BLOCK	1', '#define ERX_RNG_OUTPUT_BLOCK	0'],
      'read keeps its key' => ["\t\t__builtin_memcpy(rng->key, next, sizeof(rng->key));\n", "\t\t;\n"],
      'mix drops the digest' => ['rng->key[index] = next[index] ^ digest->bytes[index];',
                                 'rng->key[index] = next[index];'],
      'mix keeps the old key' => ['rng->key[index] = next[index] ^ digest->bytes[index];',
                                  'rng->key[index] ^= digest->bytes[index] ^ (next[index] & 0);'],
      'bound off by one' => ['length > ERX_RNG_READ_MAX)', 'length > ERX_RNG_READ_MAX + 1)'],
      'unseeded reads' => ['if (!rng->ready || length > ERX_RNG_READ_MAX)', 'if (length > ERX_RNG_READ_MAX)'],
      'clear keeps the generator ready' => ["\terx_explicit_bzero(rng, sizeof(*rng));\n}\n\nvoid\nerx_rng_digest",
                                            "\terx_explicit_bzero(rng->key, sizeof(rng->key));\n}\n\nvoid\nerx_rng_digest"]
    }
    requests = ['rng r:8 i:00 r:32 r:257 m:6162 r:16 c r:4', 'rng i: m: r:0']
    expected = @driver.ask(requests)
    mutants.each_with_index do |(name, (original, replacement)), index|
      _path, program = @driver.mutant('kernel/core/rng.c', original, replacement, index: index)
      refute_equal expected, @driver.ask_with(program, requests), "mutant survived: #{name}"
    end
  end

  def test_core_builds_freestanding_for_the_target
    @driver.compile_for_target(File.join(F::ROOT, 'kernel/core/rng.c'))
  end

  private

  def request(ops)
    words = ops.map do |op|
      case op
      in [:read, length] then "r:#{length}"
      in [:mix, bytes] then "m:#{bytes.empty? ? '' : F.hex(bytes)}"
      in [:init, bytes] then "i:#{bytes.empty? ? '' : F.hex(bytes)}"
      in [:clear] then 'c'
      end
    end
    "rng #{words.join(' ')}"
  end

  def expected(ops)
    model = F::Generator.new
    words = ops.map do |op|
      head = case op
             in [:read, length]
               output = model.read(length)
               output ? "r:ok:#{F.hex(output)}" : 'r:refused'
             in [:mix, bytes] then model.mix(bytes) ? 'm:ok' : 'm:refused'
             in [:init, bytes]
               model.init(bytes)
               'i'
             in [:clear]
               model.clear
               'c'
             end
      "#{head}:#{F.hex(model.key)}:#{model.ready ? 1 : 0}"
    end
    "rng #{words.join(' ')}"
  end

  # The answer's operations as [KIND, (OUT,) KEY, READY], KIND one of :read
  # (with OUT), :refused, :mix, :mix_refused, :init and :clear.
  def parse(line)
    words = line.split(' ')
    raise Erx::Error, "not an rng answer: #{line}" unless words.shift == 'rng'

    words.map do |word|
      case word.split(':')
      in ['r', 'ok', output, key, ready] then [:read, output, key, ready]
      in ['r', 'refused', key, ready] then [:refused, key, ready]
      in ['m', 'ok', key, ready] then [:mix, key, ready]
      in ['m', 'refused', key, ready] then [:mix_refused, key, ready]
      in ['i', key, ready] then [:init, key, ready]
      in ['c', key, ready] then [:clear, key, ready]
      end
    end
  end
end
