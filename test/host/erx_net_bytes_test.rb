# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The network stack's per-byte primitives, erx_bytes:inet_csum/2, inet_csum_update/3 and
# siphash24/2 (docs/design-runtime.md, "Per-byte primitives"), in their C cores
# (otp/erts/emulator/nifs/erxos/erx_inet_csum.c and erx_siphash.c):
# * each core's harness (test/fixtures/erx_*_harness.c) passes the published examples and
#   vectors, its cuts and its model under the address and undefined sanitizers, and fails for
#   every mutant, each changing one expression of the core;
# * each fuzz target is declared over its core, its seeds pass, and they catch a seeded fault;
# * the cores agree with the Erlang models of the host stand-in
#   (test/erlang/host_bytes/erx_bytes.erl) over random cases, through
#   test/fixtures/erx_bytes_cases.c and test/erlang/erx_bytes_cases.erl, and the models pass
#   their EUnit cases (test/erlang/erx_bytes_tests.erl, with the contract of
#   test/fixtures/erx_net_bytes_probe.erl) on stock's emulator (ERX_ERL and ERX_ERLC, which
#   make check supplies).
class ErxNetBytesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-fno-omit-frame-pointer',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  ERLANG = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_bytes_cases.erl
              test/erlang/erx_bytes_tests.erl test/fixtures/erx_net_bytes_probe.erl].map { |path| File.join(ROOT, path) }.freeze
  RANDOM_CASES = 600

  Core = Data.define(:kind, :source, :harness, :done, :mutants, :fuzz_catches)

  CORES = [
    Core.new(
      kind: 'inet_csum', source: 'erx_inet_csum.c', harness: 'erx_inet_csum_harness.c', done: 'erx_inet_csum done',
      mutants: {
        'a single fold' => ['while (total > 0xffffu)', 'if (total > 0xffffu)'],
        'odd start not swapped' => ['piece = (uint16_t)(piece << 8 | piece >> 8);', '(void)piece;'],
        'last odd byte in the low half' => ['total += (uint64_t)data[i] << 8;', 'total += data[i];'],
        'update adds the words before' => ['total += 0xffffu ^ (', 'total += 0x0000u ^ ('],
        'update skips the last word' => ['for (i = 0; i + 1 < length; i += 2) {', 'for (i = 0; i + 3 < length; i += 2) {'],
        'update takes the field uncomplemented' => ['uint64_t total = (uint16_t)~checksum;', 'uint64_t total = checksum;']
      },
      fuzz_catches: ['odd start not swapped', 'update skips the last word']
    ),
    Core.new(
      kind: 'siphash', source: 'erx_siphash.c', harness: 'erx_siphash_harness.c', done: 'erx_siphash done',
      mutants: {
        'a rotation off by one' => ['v[1] = ROTL(v[1], 13);', 'v[1] = ROTL(v[1], 12);'],
        'no finishing constant' => ['v[2] ^= 0xffu;', 'v[2] ^= 0u;'],
        'three finishing rounds' => ['rounds(v, 4);', 'rounds(v, 3);'],
        'length byte cut to seven bits' => ['(state->length & 0xffu) << 56', '(state->length & 0x7fu) << 56'],
        'a completed pending word dropped' => ['compress(state->v, load64(state->pending));', ';'],
        'key halves swapped' => ['uint64_t k0 = load64(key), k1 = load64(key + 8);',
                                 'uint64_t k1 = load64(key), k0 = load64(key + 8);']
      },
      fuzz_catches: ['length byte cut to seven bits', 'a completed pending word dropped']
    )
  ].freeze

  def test_each_harness_passes
    CORES.each do |core|
      Dir.mktmpdir("erx-#{core.kind}-") do |directory|
        output, status = build_and_run(directory, core, File.join(NIFS, core.source))
        assert status.success?, output
        assert_match(/^#{core.done}$/, output)
      end
    end
  end

  def test_every_mutant_fails_its_harness
    CORES.each do |core|
      core.mutants.each do |name, (original, replacement)|
        Dir.mktmpdir("erx-#{core.kind}-mutant-") do |directory|
          output, status = build_and_run(directory, core, mutate(directory, core, original, replacement))
          refute status.success?, "#{core.kind} mutant survived the harness: #{name}"
          refute_match(/#{core.done}/, output)
        end
      end
    end
  end

  def test_each_fuzz_target_declares_its_core_and_its_seeds_pass
    CORES.each do |core|
      Dir.mktmpdir("erx-#{core.kind}-fuzz-") do |directory|
        output, status = run_fuzz(directory, core, File.join(NIFS, core.source))
        assert status.success?, output
      end
    end
  end

  def test_each_fuzz_target_catches_its_seeded_faults
    CORES.each do |core|
      core.fuzz_catches.each do |name|
        original, replacement = core.mutants.fetch(name)
        Dir.mktmpdir("erx-#{core.kind}-fuzz-mutant-") do |directory|
          _output, status = run_fuzz(directory, core, mutate(directory, core, original, replacement))
          refute status.success?, "the #{core.kind} fuzz target did not catch the seeded fault: #{name}"
        end
      end
    end
  end

  def test_the_cores_agree_with_the_erlang_models
    Dir.mktmpdir('erx-net-bytes-diff-') do |directory|
      cases = File.join(directory, 'cases.txt')
      File.write(cases, random_cases(Random.new(1071)).join("\n") << "\n")
      c_answers = c_answers(directory, cases)
      erlang_answers = erlang_answers(directory, cases)
      assert_equal RANDOM_CASES, c_answers.size
      c_answers.zip(erlang_answers, File.readlines(cases, chomp: true)).each do |c, erlang, line|
        assert_equal c, erlang, "the C core and the Erlang model differ on: #{line[0, 200]}"
      end
    end
  end

  def test_the_erlang_models_pass_their_eunit_cases
    Dir.mktmpdir('erx-net-bytes-eunit-') do |directory|
      compile_erlang(directory)
      output, status = run_erlang(directory, 'halt(case eunit:test([erx_bytes_tests], [verbose]) of ok -> 0; _ -> 1 end)')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  # Random cases of erx_bytes_cases.c's format: inputs cut into up to five pieces of any
  # length, some all ff or all zero, and updates whose words before and after are either.
  def random_cases(random)
    fills = [->(n) { random.bytes(n) }, ->(n) { "\xff".b * n }, ->(n) { "\0".b * n }]
    hex = ->(bytes) { bytes.empty? ? '-' : bytes.unpack1('H*') }
    pieces = lambda do
      bytes = fills.sample(random: random).call([0, 1, 2, 7, 64, 1500, 9001].sample(random: random))
      cuts = Array.new(random.rand(5)) { random.rand(bytes.size + 1) }.sort
      [0, *cuts, bytes.size].each_cons(2).map { |from, to| hex.call(bytes.byteslice(from, to - from)) }
    end
    Array.new(RANDOM_CASES) do |index|
      case index % 3
      when 0 then ['sum', format('%x', random.rand(0x10000)), *pieces.call].join(' ')
      when 1
        size = 2 * random.rand(5)
        ['update', format('%x', random.rand(0x10000)),
         *Array.new(2) { hex.call(fills.sample(random: random).call(size)) }].join(' ')
      else ['sip', hex.call(random.bytes(16)), *pieces.call].join(' ')
      end
    end
  end

  def c_answers(directory, cases)
    program = File.join(directory, 'cases')
    output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', NIFS, '-I', File.join(ROOT, 'include'),
                                     File.join(ROOT, 'test/fixtures/erx_bytes_cases.c'),
                                     File.join(NIFS, 'erx_inet_csum.c'), File.join(NIFS, 'erx_siphash.c'),
                                     '-o', program, stdin_data: '')
    assert status.success?, output
    output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program,
                                     stdin_data: File.read(cases))
    assert status.success?, output
    output.lines(chomp: true)
  end

  def erlang_answers(directory, cases)
    compile_erlang(directory)
    output, status = run_erlang(directory, "erx_bytes_cases:answer(\"#{cases}\"), halt().")
    assert status.success?, output
    output.lines(chomp: true)
  end

  def compile_erlang(directory)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', directory, *ERLANG, stdin_data: '')
    assert status.success?, output
  end

  def run_erlang(directory, expression)
    Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', directory,
                    '-eval', expression, chdir: directory, stdin_data: '')
  end

  def mutate(directory, core, original, replacement)
    source = File.read(File.join(NIFS, core.source))
    raise "mutation site is gone: #{original}" unless source.include?(original)

    path = File.join(directory, core.source)
    File.write(path, source.sub(original) { replacement })
    path
  end

  def build_and_run(directory, core, source)
    program = File.join(directory, 'harness')
    output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', NIFS, '-I', File.join(ROOT, 'include'),
                                     File.join(ROOT, 'test/fixtures', core.harness), source, '-o', program,
                                     stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, stdin_data: '')
  end

  # Builds the fuzz program with the gate's own command, source standing in for the target's
  # core, and runs it once over the target's seeds.
  def run_fuzz(directory, core, source)
    target = Erx::PackFuzz.targets.find { |candidate| candidate.kind == core.kind }
    refute_nil target, "#{core.kind} fuzz target is not declared"
    core_path = File.join(NIFS, core.source)
    assert_equal [core_path.delete_prefix("#{ROOT}/")], target.sources
    corpus = File.join(directory, 'corpus')
    FileUtils.mkdir_p(corpus)
    target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(directory, 'fuzz')
    command = Erx::PackFuzz.compile_command(target, root: ROOT, compiler: COMPILER, program: program)
    command = command.map { |argument| argument == core_path ? source : argument }
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, '-runs=0', corpus,
                    stdin_data: '', chdir: directory)
  end
end
