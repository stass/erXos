# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/dependencies'

# CUBIC's fixed-point arithmetic against FreeBSD's own (docs/design-network-stack.md, "The
# send log, loss and congestion: properties and a FreeBSD oracle"): tools/fuzz/cubic_oracle.c
# compiles cubic_k and cubic_cwnd from cc_cubic.h at the pinned commit (deps.lock's
# freebsd-cc-cubic) on the host, and erx_tcp_cc_cubic's translations, compiled on stock's
# erlc (ERX_ERLC, ERX_ERL), must give the same result for every random input. The inputs
# stay where FreeBSD's 32-bit arithmetic is exact, as the module documents: cubic_k's window
# difference below 65,536 segments; cubic_cwnd's window, which FreeBSD returns in 32 bits,
# is compared modulo 2^32. Then a copy of the module whose K rounds each rebasing shift of s up
# instead of down must disagree, which shows the comparison reaches the code it checks.
class ErxTcpCcCubicOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = File.join(ROOT, 'erlang/apps/erx_net/src')
  INCLUDE = File.join(ROOT, 'erlang/apps/erx_net/include')
  HARNESS = File.join(ROOT, 'tools/fuzz/cubic_oracle.c')
  ROUNDS = 20_000
  INT_MAX = 2**31 - 1
  DEADLINE = '120'
  # Every subprocess runs under a deadline, started with an argument vector.
  LIMIT = ['gtimeout', '-k', '10', DEADLINE].freeze
  EXACT = 'rebase(S, P) when S >= 256 -> rebase(S bsr 3, P + 1);'
  FAULTY = 'rebase(S, P) when S >= 256 -> rebase((S + 7) bsr 3, P + 1);'
  # Reads inputs.txt, one input per line as the harness reads it, and prints each result.
  DRIVER = <<~ERLANG
    {ok, Text} = file:read_file("inputs.txt"),
    I = fun binary_to_integer/1,
    R = fun([<<"k">>, W, E]) -> erx_tcp_cc_cubic:cubic_k(I(W), I(E));
           ([<<"c">>, U, W, S, K]) -> erx_tcp_cc_cubic:cubic_cwnd(I(U), I(W), I(S), I(K))
        end,
    io:put_chars([[integer_to_binary(R(binary:split(L, <<" ">>, [global]))), $\\n]
                  || L <- binary:split(Text, <<"\\n">>, [global, trim_all])]),
    halt(0).
  ERLANG

  def test_cubic_arithmetic_agrees_with_freebsd
    source = File.read(File.join(SOURCE, 'erx_tcp_cc_cubic.erl'))
    assert_includes source, EXACT, 'erx_tcp_cc_cubic.erl lacks the text the seeded fault replaces'
    Dir.mktmpdir('erx-cubic-oracle') do |work|
      lines = inputs(Random.new(1))
      File.write(File.join(work, 'inputs.txt'), lines.join("\n"))
      expected = freebsd(work)
      assert_equal lines.size, expected.size

      divergence = first_divergence(lines, expected, erlang(work, source))
      assert_nil divergence, divergence

      faulty = first_divergence(lines, expected, erlang(work, source.sub(EXACT, FAULTY)))
      refute_nil faulty, 'a K that rounds the rebasing of s up agrees with FreeBSD'
      assert_match(/\Ainput "k /, faulty)
    end
  end

  private

  # Half cubic_k inputs, half cubic_cwnd inputs with t near K, where the cubic is not cut.
  def inputs(random)
    Array.new(ROUNDS) do
      if random.rand(2).zero?
        epoch = random.rand(1 << 20)
        "k #{[epoch + random.rand(-64...65_536), 0].max} #{epoch}"
      else
        k = random.rand(1 << 19)
        usecs = ((k * 1_000_000 >> 8) + random.rand(-2_000_000_000..2_000_000_000)).clamp(0, INT_MAX)
        "c #{usecs} #{random.rand(1 << 32)} #{1 + random.rand(65_535)} #{k}"
      end
    end
  end

  def freebsd(work)
    _, header = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-cc-cubic')
    include = File.join(work, 'include')
    FileUtils.mkdir_p(File.join(include, 'sys'))
    FileUtils.cp(header, File.join(include, 'cc_cubic.h'))
    File.write(File.join(include, 'sys/limits.h'), "#include <limits.h>\n")
    binary = File.join(work, 'cubic_oracle')
    execute(*LIMIT, ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-O1', '-Wall', '-Wextra', '-Werror', '-I', include,
        '-o', binary, HARNESS, '-lm')
    execute(*LIMIT, binary, stdin: File.read(File.join(work, 'inputs.txt'))).lines.map(&:to_i)
  end

  def erlang(work, cubic_source)
    Dir.mktmpdir('erl', work) do |directory|
      cubic = File.join(directory, 'erx_tcp_cc_cubic.erl')
      File.write(cubic, cubic_source)
      execute(*LIMIT, ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-pa', directory, '-o', directory,
          File.join(SOURCE, 'erx_tcp_cc.erl'), cubic)
      execute(*LIMIT, ENV.fetch('ERX_ERL'), '-noshell', '-pa', directory, '-eval', DRIVER,
          chdir: work).lines.map(&:to_i)
    end
  end

  def first_divergence(lines, expected, actual)
    assert_equal lines.size, actual.size, 'erx_tcp_cc_cubic gave another number of results'
    lines.zip(expected, actual).each do |line, theirs, ours|
      agrees = line.start_with?('c ') ? theirs == ours % 2**32 : theirs == ours
      return "input \"#{line}\": FreeBSD #{theirs}, erx_tcp_cc_cubic #{ours}" unless agrees
    end
    nil
  end

  def execute(*command, stdin: '', chdir: ROOT)
    output, error, status = Open3.capture3(*command, stdin_data: stdin, chdir: chdir)
    assert status.success?, "#{command.first} failed:\n#{error}#{output}"
    output
  end
end
