# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require_relative '../fixtures/crypto_fixture'

# Judges the kernel's entropy generator, kernel/core/rng.c, against
# CryptoFixture::Generator, a model written from the design's statements
# on OpenSSL's ChaCha20 and b3sum's BLAKE3. Seeded random sequences of
# inits, reads, mixes and clears must agree with the model in every output,
# every key and every refusal. Hand cases pin the refusals of a generator
# nobody seeded, the read bound, the first key against RFC 8439's published
# zero-key block, the fast key erasure (a read's new key never appears in
# what it returned, and every read moves the key) and the mixing rule. The
# driver stops if a spent digest is left unerased. Seeded one-line mutants
# of each rule must each fail. A differential run over the dead stack finds
# what the calls leave there: two messages, or two keys, must leave the same
# bytes, at the levels the stack proof reads, and a missing or too shallow burn
# must not. That run builds for the host, whose frames resemble but are not the
# kernel's: the stack proof holds the depth on the kernel's own objects.
class RngTest < Minitest::Test
  F = CryptoFixture
  SEED = 57
  # RFC 8439, A.1, test vector 1: the first 32 bytes of the zero key's
  # block 0.
  ZERO_KEY_BLOCK0 = '76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7'

  def setup
    @driver = F::Driver.new(name: 'rng')
    @level_drivers = {}
  end

  def teardown
    [@driver, *@level_drivers.values].each(&:remove) if passed?
  end

  def test_random_sequences_agree_with_the_model
    random = Random.new(SEED)
    sequences = Array.new(80) do
      Array.new(random.rand(1..12)) do
        case random.rand(12)
        when 0..4 then [:read, [0, 1, 31, 32, 33, 63, 64, 65, 255, 256, 257, random.rand(0..300)].sample(random: random)]
        when 5..7 then [:mix, random.bytes(random.rand(0..(random.rand(4).zero? ? F::DIGEST_INPUT_MAX : 300)))]
        when 8..10 then [:init, random.bytes(random.rand(0..64))]
        else [:clear]
        end
      end
    end
    answers = @driver.ask(sequences.map { |ops| request(ops) })
    digests = @driver.blake3_table(sequences.flatten(1).filter_map { |op| op[1] if %i[mix init].include?(op[0]) })
    sequences.zip(answers).each do |ops, answer|
      assert_equal expected(ops, digests), answer, "operations #{ops.map(&:first).inspect}"
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
    digest = @driver.blake3_table([seed]).fetch(seed)
    expected = F.unhex(ZERO_KEY_BLOCK0).bytes.zip(digest.bytes).map { |a, b| a ^ b }.pack('C*')
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
    digest = @driver.blake3_table([message]).fetch(message)
    expected = block0.bytes.zip(digest.bytes).map { |a, b| a ^ b }.pack('C*')
    assert_equal [:mix, F.hex(expected), '1'], answers[0][1]
    # Mixing nothing still spends the key; the same bytes from another key
    # give another key; the key is never the bare digest.
    refute_equal answers[1][0][1], answers[1][1][1]
    refute_equal answers[0][1][1], answers[2][1][1]
    refute_equal F.hex(digest), answers[0][1][1]
  end

  # Up to one chunk, a digest is BLAKE3's as b3sum computes it; past that it
  # is refused, and the driver stops unless the refusal left it all zeroes.
  def test_a_digest_is_blake3s_up_to_one_chunk_and_refused_past_it
    random = Random.new(SEED)
    messages = [0, 1, 63, 64, 65, 504, 1023, F::DIGEST_INPUT_MAX].map { |length| random.bytes(length) }
    digests = @driver.blake3_table(messages)
    answers = parse(@driver.ask([digest_request(messages)]).first)
    assert_equal messages.map { |message| F.hex(digests.fetch(message)) }, answers.map { |answer| answer[1] }
    assert_equal [:digest], answers.map(&:first).uniq
    too_long = [F::DIGEST_INPUT_MAX + 1, 4096].map { |length| random.bytes(length) }
    assert_equal [:digest_refused], parse(@driver.ask([digest_request(too_long)]).first).map(&:first).uniq
  end

  def test_a_digest_bound_past_one_chunk_is_caught
    request = digest_request(["\0".b * (F::DIGEST_INPUT_MAX + 1)])
    _path, program = @driver.mutant('kernel/crypto/blake3/blake3.c', 'if (length > BLAKE3_CHUNK_LEN) {',
                                    'if (length > BLAKE3_CHUNK_LEN + 1) {', index: 100)
    refute_equal @driver.ask([request]), @driver.ask_with(program, [request])
  end

  # A caller that falls through a refusal must not key a generator from the
  # zero key's public block.
  def test_a_refused_digest_keys_nothing
    too_long = F.hex("\0".b * (F::DIGEST_INPUT_MAX + 1))
    assert_equal [[:init, F.hex(F::ZERO_KEY), '0']], parse(@driver.ask(["rng i:#{too_long}"]).first)
    answers = parse(@driver.ask(["rng i:00 m:#{too_long}"]).first)
    assert_equal [:mix_refused, *answers[0][1, 2]], answers[1]
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
      'a refused digest is mixed' => ['keyed = rng->ready && digest->hashed &&', 'keyed = rng->ready &&'],
      'clear keeps the generator ready' => ["erx_rng_clear(erx_rng_t *rng)\n{\n\terx_explicit_bzero(rng, sizeof(*rng));",
                                            "erx_rng_clear(erx_rng_t *rng)\n{\n\terx_explicit_bzero(rng->key, sizeof(rng->key));"]
    }
    requests = ['rng r:8 i:00 r:32 r:257 m:6162 r:16 c r:4', 'rng i: m: r:0',
                "rng i:#{F.hex("\0".b * (F::DIGEST_INPUT_MAX + 1))}"]
    expected = @driver.ask(requests)
    mutants.each_with_index do |(name, (original, replacement)), index|
      _path, program = @driver.mutant('kernel/core/rng.c', original, replacement, index: index)
      refute_equal expected, @driver.ask_with(program, requests), "mutant survived: #{name}"
    end
  end

  # Message lengths reaching every path of the hash: a part of a block, a
  # block alone, one more byte, the longest bytes a domain can mix and a
  # whole chunk.
  RESIDUE_LENGTHS = [1, 64, 65, 504, F::DIGEST_INPUT_MAX].freeze

  def test_the_generators_calls_leave_nothing_secret_on_the_stack
    skip 'a sanitizer changes the frames the burn is sized for' if sanitized?

    requests = residue_requests
    %w[-O0 -O2].each do |level|
      residue(driver_at(level).ask(requests)).zip(requests).each do |found, request|
        assert_equal 0, found.differing, "#{request.split[1]} of #{request.split[2].size / 2} bytes at #{level}"
        assert_operator found.touched, :>, 0, 'the stretch read is not where the call ran'
      end
    end
  end

  # Each is judged on the calls of its own kind alone, so a burn too shallow for
  # the hash cannot die on a read's residue instead.
  BurnMutant = Data.define(:name, :kind, :original, :replacement, :levels)
  # The hash's frame at -O0 is deeper than 768 bytes on an AArch64 host, the
  # architecture the burn is sized for, and shallower on x86-64, where a 768-byte
  # burn still covers it and that seed is no fault.
  AARCH64_HOST = %w[arm64 aarch64].include?(RbConfig::CONFIG.fetch('host_cpu'))
  BURN_MUTANTS = [
    BurnMutant.new(name: 'hash without a burn', kind: 'hash',
                   original: "\terx_rng_burn_stack();\n\treturn (hashed);",
                   replacement: "\tif (length == SIZE_MAX)\n\t\terx_rng_burn_stack();\n\treturn (hashed);", levels: %w[-O0 -O2]),
    BurnMutant.new(name: 'a burn too shallow', kind: 'hash',
                   original: "#define ERX_RNG_BURN_BYTES\t976",
                   replacement: "#define ERX_RNG_BURN_BYTES\t128", levels: %w[-O0 -O2]),
    BurnMutant.new(name: 'a burn shallower than the hash at -O0', kind: 'hash',
                   original: "#define ERX_RNG_BURN_BYTES\t976",
                   replacement: "#define ERX_RNG_BURN_BYTES\t768", levels: AARCH64_HOST ? %w[-O0] : []),
    BurnMutant.new(name: 'read without a burn', kind: 'read',
                   original: "\terx_rng_burn_stack();\n\treturn (served);",
                   replacement: "\tif (rng == NULL)\n\t\terx_rng_burn_stack();\n\treturn (served);", levels: %w[-O0 -O2]),
    BurnMutant.new(name: 'mix without a burn', kind: 'mix',
                   original: "\terx_rng_burn_stack();\n\treturn (keyed);",
                   replacement: "\tif (rng == NULL)\n\t\terx_rng_burn_stack();\n\treturn (keyed);", levels: %w[-O0 -O2])
  ].freeze

  def test_a_missing_or_shallow_burn_is_caught
    skip 'a sanitizer changes the frames the burn is sized for' if sanitized?

    requests = residue_requests
    BURN_MUTANTS.each_with_index do |mutant, index|
      mutant.levels.each do |level|
        driver = driver_at(level)
        _path, program = driver.mutant('kernel/core/rng.c', mutant.original, mutant.replacement, index: index)
        judged = requests.select { |request| request.split[1] == mutant.kind }
        found = residue(driver.ask_with(program, judged)).map(&:differing)
        assert_operator found.max, :>, 0, "mutant survived at #{level}: #{mutant.name}"
      end
    end
  end

  def test_core_builds_freestanding_for_the_target
    @driver.compile_for_target(File.join(F::ROOT, 'kernel/core/rng.c'))
  end

  private

  def sanitized? = !ENV.fetch('ERX_SANITIZERS', '').empty?

  def digest_request(messages) = "rng #{messages.map { |bytes| "d:#{bytes.empty? ? '' : F.hex(bytes)}" }.join(' ')}"

  def driver_at(level)
    @level_drivers[level] ||= F::Driver.new(name: "rng#{level.delete('-').downcase}", level: level)
  end

  # Two secrets that differ in every byte, so no word of either can pass for
  # the other's: messages of each length, then keys for a read and a mix.
  def residue_requests
    random = Random.new(SEED)
    calls = RESIDUE_LENGTHS.map { |length| ['hash', length] } + [['read', F::KEY_BYTES], ['mix', F::KEY_BYTES]]
    calls.map do |kind, length|
      first = random.bytes(length)
      second = first.bytes.map { |byte| byte ^ 0x5a }.pack('C*')
      "rng-residue #{kind} #{F.hex(first)} #{F.hex(second)}"
    end
  end

  Residue = Data.define(:differing, :touched)

  def residue(lines)
    lines.map do |line|
      line.split => ['rng-residue', differing, touched]
      Residue.new(differing: Integer(differing), touched: Integer(touched))
    end
  end

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

  def expected(ops, digests)
    model = F::Generator.new(digests: digests)
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
  # (with OUT), :refused, :mix, :mix_refused, :init, :digest (with the digest as
  # OUT), :digest_refused and :clear.
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
      in ['d', 'ok', digest, key, ready] then [:digest, digest, key, ready]
      in ['d', 'refused', key, ready] then [:digest_refused, key, ready]
      in ['c', key, ready] then [:clear, key, ready]
      end
    end
  end
end
