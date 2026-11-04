# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'

# Builds test/fixtures/crypto_driver.c with the imported SHA-256, ChaCha20
# and BLAKE3 and the entropy generator, runs batches of requests through it,
# and holds the references the host tests judge it by: Ruby's Digest for
# SHA-256, the host's OpenSSL for RFC 8439 ChaCha20 and b3sum, BLAKE3's Rust
# implementation, for BLAKE3, all independent of the code under test, and a
# model of the generator written from the design's statements on top of
# them.
module CryptoFixture
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[kernel/crypto/sha2/sha256c.c kernel/crypto/chacha20/chacha.c kernel/crypto/blake3/blake3.c
               kernel/crypto/blake3/blake3_portable.c kernel/core/rng.c].freeze
  KEY_BYTES = 32
  NONCE_BYTES = 12
  BLOCK_BYTES = 64
  READ_MAX = 256
  ZERO_KEY = ("\0" * KEY_BYTES).b.freeze
  ZERO_NONCE = ("\0" * NONCE_BYTES).b.freeze
  # The context the driver prints after erx_sha256_final: 8 state words,
  # the 64-bit count and the 64-byte buffer, all erased.
  ERASED_SHA256_CONTEXT = ('00' * (32 + 8 + 64)).freeze

  # The driver and its working directory, built once per test.
  class Driver
    attr_reader :directory

    # level is the optimization level the driver and the code under test
    # build at.
    def initialize(name:, sources: SOURCES.map { |source| File.join(ROOT, source) }, level: '-O1')
      @level = level
      @directory = Dir.mktmpdir("erx-#{name}-")
      @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
      sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
      raise Erx::Error, 'unsupported crypto-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

      @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
      @program = build(sources, name: name)
    end

    def compiler = ENV.fetch('ERX_CLANG', 'clang')

    # One answer line per request line, in order.
    def ask(requests)
      input = File.join(@directory, 'requests.txt')
      File.write(input, requests.map { |request| "#{request}\n" }.join)
      record = @runner.run([@program, input], name: 'crypto-driver', deadline: 300)
      lines = File.readlines(record.fetch('log'), chomp: true)
      raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size

      lines
    end

    # Compiles source for the kernel's target, freestanding, as the core
    # archive does.
    def compile_for_target(source)
      @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2',
                   '--target=aarch64-none-elf', '-ffreestanding', '-mgeneral-regs-only', '-mno-outline-atomics',
                   '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'kernel/crypto'), '-c', source,
                   '-o', File.join(@directory, "#{File.basename(source, '.c')}.o")],
                  name: "compile-target-#{File.basename(source, '.c')}", deadline: 60)
    end

    # A driver built with one source replaced by a copy in which original,
    # which must occur exactly once, reads replacement.
    def mutant(source, original, replacement, index:)
      text = File.read(File.join(ROOT, source))
      raise Erx::Error, "mutant must edit exactly one place in #{source}" unless text.scan(original).size == 1

      path = File.join(@directory, "mutant-#{index}-#{File.basename(source)}")
      File.write(path, text.sub(original) { replacement })
      sources = SOURCES.map { |name| name == source ? path : File.join(ROOT, name) }
      [path, build(sources, name: "mutant-#{index}")]
    end

    def ask_with(program, requests)
      saved = @program
      @program = program
      ask(requests)
    ensure
      @program = saved
    end

    # BLAKE3 digests of messages, as a table from each message to its bytes.
    def blake3_table(messages)
      unique = messages.uniq
      unique.zip(CryptoFixture.b3sum(unique, directory: @directory, runner: @runner)
                              .map { |digest| CryptoFixture.unhex(digest) }).to_h
    end

    def remove = FileUtils.remove_entry(@directory)

    private

    def build(sources, name:)
      output = File.join(@directory, name)
      # rng.c and the driver include the imported headers as
      # "blake3/blake3.h", "sha2/sha256.h" and "chacha20/chacha.h", found
      # through -I kernel/crypto. A mutant's copy lives outside the tree, so the
      # imported sources' own includes of the header beside them
      # ("sha256.h", "chacha.h") need those directories on the path too.
      includes = %w[include kernel/crypto kernel/crypto/sha2 kernel/crypto/chacha20].flat_map do |directory|
        ['-I', File.join(ROOT, directory)]
      end
      @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', @level, '-g',
                   *@sanitizer_flags, *includes, *sources,
                   File.join(ROOT, 'test/fixtures/crypto_driver.c'), '-o', output],
                  name: "compile-#{name}", deadline: 120)
      output
    end
  end

  module_function

  def hex(bytes) = bytes.empty? ? '-' : bytes.unpack1('H*')

  def unhex(text) = text == '-' ? ''.b : [text].pack('H*')

  # RFC 8439 ChaCha20 through the host's OpenSSL, whose 16-byte IV is the
  # 32-bit little-endian block counter followed by the 96-bit nonce.
  def chacha20(key:, counter:, nonce:, data:)
    return ''.b if data.empty?

    cipher = OpenSSL::Cipher.new('chacha20')
    cipher.encrypt
    cipher.key = key
    cipher.iv = [counter].pack('V') + nonce
    cipher.update(data) + cipher.final
  end

  def sha256(bytes) = Digest::SHA256.digest(bytes)

  # The hexadecimal BLAKE3 digest of each message, in order, from b3sum,
  # BLAKE3's Rust implementation. directory receives the messages' files.
  def b3sum(messages, directory:, runner:)
    return [] if messages.empty?

    tool = ENV.fetch('ERX_B3SUM') do
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |entry| File.join(entry, 'b3sum') }
         .find { |path| File.executable?(path) }
    end
    raise Erx::Error, 'b3sum is the differential oracle and is not installed (brew install b3sum)' if tool.nil?

    paths = messages.each_with_index.map do |message, index|
      File.join(directory, "message-#{index}").tap { |path| File.binwrite(path, message) }
    end
    record = runner.run([tool, '--no-names', *paths], name: 'b3sum', deadline: 120)
    digests = File.readlines(record.fetch('log'), chomp: true)
    raise Erx::Error, "b3sum gave #{digests.size} digests for #{paths.size} messages" unless digests.size == paths.size

    digests
  end

  # The generator from the design: a read's output is the key stream from
  # block 1 and its new key the first 32 bytes of block 0; a mix's new key
  # is those 32 bytes XORed with the BLAKE3 digest of the mixed bytes, which
  # digests, a table from messages to digests, holds. From the core's
  # interface: init mixes its seed into the zero key and makes the generator
  # ready; it starts, and a clear leaves it, not ready, all zeroes, refusing
  # reads and mixes.
  class Generator
    attr_reader :key, :ready

    def initialize(digests:)
      @digests = digests
      clear
    end

    def read(length)
      return nil if !@ready || length > READ_MAX

      output = CryptoFixture.chacha20(key: @key, counter: 1, nonce: ZERO_NONCE, data: "\0".b * length)
      @key = next_block_key
      output
    end

    def mix(bytes)
      return false unless @ready

      @key = next_block_key.bytes.zip(@digests.fetch(bytes).bytes).map { |a, b| a ^ b }.pack('C*')
      true
    end

    def init(bytes)
      @key = ZERO_KEY
      @ready = true
      mix(bytes)
    end

    def clear
      @key = ZERO_KEY
      @ready = false
    end

    private

    def next_block_key = CryptoFixture.chacha20(key: @key, counter: 0, nonce: ZERO_NONCE, data: "\0".b * KEY_BYTES)
  end
end
