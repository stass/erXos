# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/json_input'
require_relative '../../tools/lib/erx/core_archive'

# The imported BLAKE3 (kernel/crypto/blake3/) against two oracles that share
# no code with it: the official test vectors imported beside it, and
# b3sum, BLAKE3's Rust implementation, over seeded random messages fed in
# random pieces. test/fixtures/blake3_driver.c runs the C code; mutants of
# it must fail the same checks.
class Blake3Test < Minitest::Test
  BLAKE3 = 'kernel/crypto/blake3'
  SOURCES = %W[#{BLAKE3}/blake3.c #{BLAKE3}/blake3_portable.c].freeze
  VECTORS = "#{BLAKE3}/test_vectors.json"
  DIGEST_HEX = 64
  CHUNK = 1024
  # The context's size on the 64-bit hosts and targets erXos builds for,
  # which blake3.h states; blake3.c bounds it at 2048 bytes.
  CONTEXT_BYTES = 1912
  # Lengths at and around every block, chunk and tree boundary the vectors
  # do not already pin, then random ones.
  BOUNDARY_LENGTHS = [0, 1, 63, 64, 65, 127, 128, 1023, 1024, 1025, 2047, 2048, 2049, 3071, 3072, 3073,
                      4095, 4096, 4097, 5 * CHUNK, 7 * CHUNK + 1, 8 * CHUNK, 16 * CHUNK + 63,
                      31 * CHUNK, 32 * CHUNK, 33 * CHUNK + 1, 128 * CHUNK, 1000 * CHUNK + 1].freeze
  SEED = 20_261_103

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-blake3-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported blake3-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build(SOURCES.map { |source| File.join(@root, source) }, name: 'blake3')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_the_official_vectors_hold_whole_and_in_pieces
    cases = vectors
    assert_equal 35, cases.size
    requests = cases.flat_map do |message, _digest|
      [request(message), request(message, pieces: [1, 63, 64, 1023, 1024, 1025])]
    end
    answers = ask(@driver, requests)
    cases.flat_map { |message, digest| [[message, digest]] * 2 }.zip(answers).each do |(message, digest), answer|
      assert_equal "hash #{digest} 1", answer, "#{message.bytesize}-byte vector"
    end
  end

  def test_random_messages_in_random_pieces_agree_with_b3sum
    random = Random.new(SEED)
    lengths = BOUNDARY_LENGTHS + Array.new(60) { random.rand(0..(64 * CHUNK)) } +
              Array.new(4) { random.rand((64 * CHUNK)..(1 << 21)) }
    messages = lengths.map { |length| random.bytes(length) }
    pieces = messages.map { |message| random_pieces(message.bytesize, random) }
    expected = b3sum(messages)
    whole = ask(@driver, messages.map { |message| request(message) })
    split = ask(@driver, messages.zip(pieces).map { |message, list| request(message, pieces: list) })
    messages.each_with_index do |message, index|
      assert_equal "hash #{expected[index]} 1", whole[index], "#{message.bytesize} bytes in one update"
      assert_equal "hash #{expected[index]} 1", split[index],
                   "#{message.bytesize} bytes in pieces #{pieces[index].first(8).inspect}"
    end
  end

  def test_every_split_of_a_message_across_three_chunks_gives_one_digest
    message = Random.new(SEED + 1).bytes(3 * CHUNK + 1)
    expected = b3sum([message]).first
    cuts = [0, 1, 63, 64, 65, 1023, 1024, 1025, 2048, 3072, 3073]
    requests = cuts.product(cuts).filter_map do |first, second|
      next if first + second > message.bytesize

      request(message, pieces: [first, second])
    end
    ask(@driver, requests).each { |answer| assert_equal "hash #{expected} 1", answer }
  end

  def test_the_context_has_its_stated_size
    assert_equal ["size #{CONTEXT_BYTES}"], ask(@driver, ['size'])
  end

  # The cores' archive flags (-mgeneral-regs-only refuses any FP or SIMD
  # register) at both levels the stack proof reads.
  def test_it_builds_with_the_cores_flags
    SOURCES.product(%w[-O0 -O2]).each do |source, level|
      object = File.join(@directory, "#{File.basename(source, '.c')}#{level}.o")
      @runner.run([compiler, *Erx::CoreArchive::FLAGS, level, '-c', source, '-o', object],
                  name: "compile-target-#{File.basename(source, '.c')}", deadline: 60, chdir: @root)
      assert File.size(object).positive?
    end
  end

  # Bootstrap and the stopgap kernel's glue are C++, so the interface
  # header compiles as C++ too, hosted and for the kernel's target.
  def test_the_header_compiles_as_cxx
    source = File.join(@directory, 'header.cpp')
    File.write(source, "#include \"blake3/blake3.h\"\n" \
                       "static_assert(sizeof(erx_blake3_ctx_t) <= 2048, \"context bound\");\n" \
                       "void hash_nothing(unsigned char *digest) {\n" \
                       "  erx_blake3_ctx_t ctx;\n  erx_blake3_init(&ctx);\n  erx_blake3_update(&ctx, nullptr, 0);\n" \
                       "  erx_blake3_final(&ctx, digest);\n}\n")
    common = ['-std=c++17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I', File.join(@root, 'kernel/crypto'),
              '-fsyntax-only', source]
    @runner.run([cxx_compiler, *common], name: 'compile-header-cxx-host', deadline: 60)
    @runner.run([cxx_compiler, '--target=aarch64-none-elf', '-ffreestanding', '-nostdinc++', '-mgeneral-regs-only',
                 *common], name: 'compile-header-cxx-target', deadline: 60)
  end

  # Each mutant changes one step of the hash; the vectors and the split
  # cases must catch every one.
  MUTANTS = [
    ["#{BLAKE3}/blake3_portable.c", 'state[d] = rotr32(state[d] ^ state[a], 16);',
     'state[d] = rotr32(state[d] ^ state[a], 15);'],
    ["#{BLAKE3}/blake3.c", 'while (input_len > BLAKE3_CHUNK_LEN) {', 'while (input_len >= BLAKE3_CHUNK_LEN) {'],
    ["#{BLAKE3}/blake3.c", 'while (input_len > ERX_BLAKE3_BLOCK_LEN) {',
     'while (input_len >= ERX_BLAKE3_BLOCK_LEN) {'],
    ["#{BLAKE3}/blake3.c", 'hasher_push_cv(self, chunk_cv, self->chunk.chunk_counter);',
     'hasher_push_cv(self, chunk_cv, self->chunk.chunk_counter + 1);'],
    ["#{BLAKE3}/blake3.c", 'self->flags | ROOT);', 'self->flags);'],
    ["#{BLAKE3}/blake3.c", 'erx_explicit_bzero(ctx, sizeof(*ctx));', '(void)ctx;']
  ].freeze

  def test_mutants_are_killed
    cases = vectors
    requests = cases.flat_map { |message, _| [request(message), request(message, pieces: [64, 1024])] }
    expected = cases.flat_map { |_, digest| ["hash #{digest} 1"] * 2 }
    MUTANTS.each_with_index do |(source, original, replacement), index|
      text = File.read(File.join(@root, source))
      assert_equal 1, text.scan(original).size, "mutant #{index} must edit exactly one place in #{source}"
      path = File.join(@directory, "mutant-#{index}-#{File.basename(source)}")
      File.write(path, text.sub(original) { replacement })
      sources = SOURCES.map { |name| name == source ? path : File.join(@root, name) }
      program = build(sources, name: "mutant-#{index}")
      refute_equal expected, ask(program, requests), "mutant #{index} (#{replacement}) survived"
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  # clang++ beside the configured clang, as the C++ driver of the same build.
  def cxx_compiler
    sibling = "#{compiler}++"
    File.executable?(sibling) ? sibling : 'clang++'
  end

  # The mutants' copies include blake3.h and blake3_impl.h from outside
  # their own directory, so the import's directory goes on the path too.
  def build(sources, name:)
    output = File.join(@directory, name)
    includes = ['include', 'kernel/crypto', BLAKE3].flat_map { |directory| ['-I', File.join(@root, directory)] }
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, *includes, *sources,
                 File.join(@root, 'test/fixtures/blake3_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def ask(program, requests)
    input = File.join(@directory, 'requests.txt')
    File.write(input, requests.map { |line| "#{line}\n" }.join)
    record = @runner.run([program, input], name: 'blake3-driver', deadline: 300)
    lines = File.readlines(record.fetch('log'), chomp: true)
    raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size

    lines
  end

  def request(message, pieces: nil)
    hex = message.empty? ? '-' : message.unpack1('H*')
    usable = pieces&.each_with_object([]) do |piece, kept|
      kept << piece if kept.sum + piece <= message.bytesize
    end
    "hash #{hex} #{usable.nil? || usable.empty? ? '-' : usable.join(',')}"
  end

  # Piece lengths summing to at most length, with empty pieces and pieces
  # on both sides of the block and chunk sizes; the driver feeds the rest
  # in one last update.
  def random_pieces(length, random)
    sizes = [0, 1, 63, 64, 65, 1023, 1024, 1025, 4096]
    list = []
    total = 0
    while list.size < 64
      piece = random.rand(2).zero? ? sizes.sample(random: random) : random.rand(0..(3 * CHUNK))
      break if total + piece > length

      list << piece
      total += piece
    end
    list
  end

  # The official vectors' messages (input_len bytes of 0, 1, ..., 250, 0,
  # ...) and their digests, the first 32 bytes of each extended output.
  def vectors
    text = File.binread(File.join(@root, VECTORS))
    Erx::JsonInput.parse(text, label: 'BLAKE3 test vectors').fetch('cases').map do |entry|
      length = entry.fetch('input_len')
      [Array.new(length) { |index| index % 251 }.pack('C*'), entry.fetch('hash')[0, DIGEST_HEX]]
    end
  end

  # BLAKE3's Rust implementation, as the b3sum tool installs it.
  def b3sum(messages)
    tool = ENV.fetch('ERX_B3SUM') do
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |entry| File.join(entry, 'b3sum') }
         .find { |path| File.executable?(path) }
    end
    flunk 'b3sum is the differential oracle and is not installed (brew install b3sum)' if tool.nil?

    paths = messages.each_with_index.map do |message, index|
      File.join(@directory, "message-#{index}").tap { |path| File.binwrite(path, message) }
    end
    record = @runner.run([tool, '--no-names', *paths], name: 'b3sum', deadline: 120)
    digests = File.readlines(record.fetch('log'), chomp: true)
    raise Erx::Error, "b3sum gave #{digests.size} digests for #{paths.size} messages" unless digests.size == paths.size

    digests
  end
end
