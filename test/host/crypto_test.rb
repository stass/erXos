# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require_relative '../fixtures/crypto_fixture'

# Judges FreeBSD's SHA-256 and ChaCha20 as erXos imported them
# (kernel/crypto/). Each is held to its specification's published values,
# FIPS 180-4's examples for SHA-256 and RFC 8439's for ChaCha20, and then
# compared with an independent reference on the host, Ruby's Digest and
# OpenSSL, over seeded random inputs cut into random pieces. ChaCha20's
# 32-bit counter is pinned at its last blocks: a stream that would need a
# block past 2^32 - 1 is refused whole and writes nothing. Seeded one-line
# mutants of the boundary check, of the counter's word and of the
# padding must each fail.
class CryptoTest < Minitest::Test
  F = CryptoFixture
  SEED = 56
  LAST = 0xffff_ffff

  # FIPS 180-4's examples (NIST's "SHA-256" example computations, the
  # same messages and digests as FIPS 180-2 Appendix B), and the empty
  # message.
  SHA256_VECTORS = {
    'abc' => 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' =>
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    '' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
  }.freeze
  # FIPS 180-2 Appendix B.3: one million repetitions of 'a'.
  MILLION_A = 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0'

  RFC_KEY = (0..31).to_a.pack('C*').freeze
  # RFC 8439, 2.3.2: the block function at counter 1.
  RFC_BLOCK_NONCE = ['000000090000004a00000000'].pack('H*').freeze
  RFC_BLOCK = '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e' \
              'd2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e'
  # RFC 8439, 2.4.2: encrypting the sunscreen text from counter 1.
  RFC_SUNSCREEN = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for " \
                  'the future, sunscreen would be it.'
  RFC_SUNSCREEN_NONCE = ['000000000000004a00000000'].pack('H*').freeze
  RFC_SUNSCREEN_CIPHER = '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b' \
                         'f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8' \
                         '07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736' \
                         '5af90bbf74a35be6b40b8eedf2785e42874d'
  # RFC 8439, A.1, test vectors 1 and 2: the zero key and nonce at
  # counters 0 and 1.
  RFC_ZERO_BLOCKS = {
    0 => '76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7' \
         'da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586',
    1 => '9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed' \
         '29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f'
  }.freeze

  def setup
    @driver = F::Driver.new(name: 'crypto')
  end

  def teardown
    @driver.remove if passed?
  end

  def test_sha256_matches_the_fips_examples
    requests = SHA256_VECTORS.keys.map { |message| "sha256 #{F.hex(message.b)} -" }
    requests << 'sha256-repeat 61 1000000 4096'
    answers = @driver.ask(requests)
    (SHA256_VECTORS.values + [MILLION_A]).zip(answers).each do |digest, answer|
      assert_equal "sha256 #{digest} #{F::ERASED_SHA256_CONTEXT}", answer
    end
    # The published digests are Digest's too, so the reference agrees.
    SHA256_VECTORS.each { |message, digest| assert_equal digest, F.hex(F.sha256(message.b)) }
  end

  def test_sha256_agrees_with_digest_over_random_messages_and_pieces
    random = Random.new(SEED)
    # Every length that ends near a block or a padding boundary, then
    # random lengths up to several blocks.
    lengths = (0..130).to_a + Array.new(200) { random.rand(0..1000) }
    cases = lengths.map do |length|
      message = random.bytes(length)
      [message, pieces(length, random)]
    end
    answers = @driver.ask(cases.map { |message, sizes| "sha256 #{F.hex(message)} #{sizes.join(',')}" })
    cases.zip(answers).each do |(message, sizes), answer|
      assert_equal "sha256 #{F.hex(F.sha256(message))} #{F::ERASED_SHA256_CONTEXT}", answer,
                   "#{message.bytesize} bytes in pieces #{sizes.inspect}"
    end
  end

  def test_sha256_takes_an_empty_update_with_no_buffer
    answers = @driver.ask(['sha256 - 0,0,0', "sha256 #{F.hex('abc'.b)} 0,1,0,2,0"])
    assert_equal "sha256 #{SHA256_VECTORS.fetch('')} #{F::ERASED_SHA256_CONTEXT}", answers[0]
    assert_equal "sha256 #{SHA256_VECTORS.fetch('abc')} #{F::ERASED_SHA256_CONTEXT}", answers[1]
  end

  def test_chacha20_matches_rfc_8439
    zero = F.hex("\0".b * 64)
    requests = ["chacha20 #{F.hex(RFC_KEY)} 1 #{F.hex(RFC_BLOCK_NONCE)} #{zero} copy",
                "chacha20 #{F.hex(RFC_KEY)} 1 #{F.hex(RFC_SUNSCREEN_NONCE)} #{F.hex(RFC_SUNSCREEN.b)} copy",
                "chacha20 #{F.hex(RFC_KEY)} 1 #{F.hex(RFC_SUNSCREEN_NONCE)} #{RFC_SUNSCREEN_CIPHER} inplace"]
    requests += RFC_ZERO_BLOCKS.keys.map do |counter|
      "chacha20 #{F.hex(F::ZERO_KEY)} #{counter} #{F.hex(F::ZERO_NONCE)} #{zero} inplace"
    end
    answers = @driver.ask(requests)
    expected = [RFC_BLOCK, RFC_SUNSCREEN_CIPHER, F.hex(RFC_SUNSCREEN.b), *RFC_ZERO_BLOCKS.values]
    expected.zip(answers).each { |output, answer| assert_equal "chacha20 ok #{output}", answer }
    assert_equal RFC_BLOCK, F.hex(F.chacha20(key: RFC_KEY, counter: 1, nonce: RFC_BLOCK_NONCE, data: "\0".b * 64))
  end

  def test_chacha20_agrees_with_openssl_over_random_streams
    random = Random.new(SEED)
    cases = Array.new(300) do |index|
      length = index < 130 ? index : random.rand(0..2000)
      # Counters from the start, anywhere, and at the last blocks that
      # still fit the stream.
      blocks = (length + 63) / 64
      counter = [0, random.rand(0..LAST - blocks), LAST + 1 - [blocks, 1].max][index % 3]
      { key: random.bytes(32), counter: counter, nonce: random.bytes(12), data: random.bytes(length),
        mode: index.even? ? 'copy' : 'inplace' }
    end
    answers = @driver.ask(cases.map do |item|
      "chacha20 #{F.hex(item[:key])} #{item[:counter]} #{F.hex(item[:nonce])} #{F.hex(item[:data])} #{item[:mode]}"
    end)
    cases.zip(answers).each do |item, answer|
      expected = F.chacha20(key: item[:key], counter: item[:counter], nonce: item[:nonce], data: item[:data])
      assert_equal "chacha20 ok #{F.hex(expected)}", answer,
                   "#{item[:data].bytesize} bytes from counter #{item[:counter]}, #{item[:mode]}"
    end
  end

  def test_chacha20_refuses_any_stream_past_the_last_block_and_writes_nothing
    key = F.hex(RFC_KEY)
    nonce = F.hex(RFC_SUNSCREEN_NONCE)
    accepted = [[LAST, 1], [LAST, 64], [LAST - 1, 128], [LAST - 1, 65], [0, 0], [LAST, 0]]
    refused = [[LAST, 65], [LAST, 128], [LAST - 1, 129], [LAST - 2, 193]]
    data = ->(length) { length.zero? ? '-' : F.hex("\x5a".b * length) }
    requests = (accepted + refused).map { |counter, length| "chacha20 #{key} #{counter} #{nonce} #{data.call(length)} copy" }
    answers = @driver.ask(requests)
    accepted.zip(answers).each do |(counter, length), answer|
      expected = F.chacha20(key: RFC_KEY, counter: counter, nonce: RFC_SUNSCREEN_NONCE, data: "\x5a".b * length)
      assert_equal "chacha20 ok #{F.hex(expected)}", answer, "counter #{counter}, #{length} bytes"
    end
    refused.zip(answers.drop(accepted.size)).each do |(counter, length), answer|
      assert_equal "chacha20 refused #{F.hex("\xa5".b * length)}", answer, "counter #{counter}, #{length} bytes"
    end
  end

  def test_chacha20_refuses_lengths_beyond_the_counter_without_touching_memory
    # 2^32 blocks from counter 0 is the whole counter; one byte more, or
    # any length from counter 1, needs block 2^32.
    whole = (1 << 32) * 64
    refused = [[0, whole + 1], [1, whole], [LAST, (1 << 64) - 1], [0, (1 << 64) - 1], [LAST, 65]]
    answers = @driver.ask(refused.map { |counter, length| "chacha20-bound #{counter} #{length}" } +
                          ['chacha20-bound 0 0', "chacha20-bound #{LAST} 0"])
    assert_equal ['chacha20 refused'] * refused.size + ['chacha20 ok'] * 2, answers
  end

  def test_mutants_fail
    mutants = {
      'boundary off by one' => ['kernel/crypto/chacha20/chacha.c', 'if (blocks > remaining)', 'if (blocks > remaining + 1)'],
      'counter value off by one' => ['kernel/crypto/chacha20/chacha.c', 'x->input[12] = counter;', 'x->input[12] = counter ^ 1;'],
      'nonce word 13 wrong' => ['kernel/crypto/chacha20/chacha.c', 'x->input[13] = U8TO32_LITTLE(iv + 0);',
                                              'x->input[13] = U8TO32_LITTLE(iv + 8);'],
      'padding at 55 mod 64' => ['kernel/crypto/sha2/sha256c.c', 'if (r < 56) {', 'if (r < 55) {']
    }
    requests = ["chacha20 #{F.hex(RFC_KEY)} #{LAST} #{F.hex(RFC_SUNSCREEN_NONCE)} #{F.hex("\0".b * 65)} copy",
                "chacha20 #{F.hex(RFC_KEY)} #{LAST - 1} #{F.hex(RFC_BLOCK_NONCE)} #{F.hex("\0".b * 128)} copy",
                "chacha20 #{F.hex(RFC_KEY)} 1 #{F.hex(RFC_BLOCK_NONCE)} #{F.hex("\0".b * 64)} copy",
                "sha256 #{F.hex('a'.b * 55)} -"]
    expected = @driver.ask(requests)
    mutants.each_with_index do |(name, (source, original, replacement)), index|
      _path, program = @driver.mutant(source, original, replacement, index: index)
      refute_equal expected, @driver.ask_with(program, requests), "mutant survived: #{name}"
    end
  end

  def test_imports_build_freestanding_for_the_target
    %w[kernel/crypto/sha2/sha256c.c kernel/crypto/chacha20/chacha.c].each do |source|
      @driver.compile_for_target(File.join(F::ROOT, source))
    end
  end

  private

  # Random piece sizes that add up to length, empty pieces included.
  def pieces(length, random)
    sizes = []
    left = length
    while left.positive?
      size = [random.rand(0..[left, 150].min), left].min
      sizes << size
      left -= size
    end
    sizes << 0 if sizes.empty? || random.rand(4).zero?
    sizes
  end
end
