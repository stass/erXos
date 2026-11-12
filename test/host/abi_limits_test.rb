# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The bounds C and Erlang share have one source, the ABI files: a limit declared there reaches
# erx/abi.h and erx_abi.hrl with the same value, a change to it in that one place moves both,
# and a limit derived from another (pipe_rix_max, one below pipe_readers_max) fails the build
# of liberx/erx_pipe_check.c when the two disagree. Each case generates the header and the
# include from a copy of abi/, compiles a probe of each with ERX_CLANG and ERX_ERLC, and
# runs the Erlang probe with ERX_ERL.
class AbiLimitsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  # The limits C and Erlang both read, whichever ABI file declares each.
  SHARED = %w[prog_report_max pipes_quota pipe_readers_max pipe_rix_max program_send_no_reply
              program_control_send program_grant_drained inspect_path_max inspect_name_max
              inspect_page_max].freeze

  def setup
    @directory = Dir.mktmpdir('erx-abi-limits-')
    FileUtils.cp_r(File.join(ROOT, 'abi'), @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && @directory && File.directory?(@directory)
  end

  def test_each_shared_limit_reaches_c_and_erlang
    schema = generate
    expected = SHARED.map { |name| schema.constants.fetch(name).value }
    assert_equal expected, c_values
    assert_equal expected, erlang_values
  end

  # A seeded change in one place: the pipes quota in abi/erx_abi.txt alone.
  def test_one_edit_moves_both_languages
    seed('abi/erx_abi.txt', 'limit pipes_quota u32 1024', 'limit pipes_quota u32 1000')
    generate
    at = SHARED.index('pipes_quota')
    assert_equal 1000, c_values.fetch(at)
    assert_equal 1000, erlang_values.fetch(at)
  end

  def test_the_pipe_check_builds_against_the_abi
    generate
    output, status = compile_pipe_check
    assert status.success?, output
  end

  # A seeded fault: pipe_readers_max changed and pipe_rix_max, which prog.txt's read ends
  # name, left as it was.
  def test_a_read_end_bound_that_disagrees_fails_the_build
    seed('abi/erx_abi.txt', 'limit pipe_readers_max u32 64', 'limit pipe_readers_max u32 32')
    generate
    output, status = compile_pipe_check
    refute status.success?, 'the pipe check built against disagreeing read end bounds'
    assert_includes output, "a read end's largest index is one below the read ends a pipe may have"
  end

  # A seeded fault: the query's path bound lowered below the inspection schema's deepest path,
  # which the inspect facet would then refuse as badarg.
  def test_a_declared_path_past_the_query_bound_fails_generation
    seed('abi/services/inspect.txt', 'limit inspect_path_max u32 16', 'limit inspect_path_max u32 2')
    error = assert_raises(Erx::Error) { generate }
    assert_match(/segments, past inspect_path_max 2/, error.message)
  end

  private

  def seed(relative, original, replacement)
    path = File.join(@directory, relative)
    source = File.read(path)
    assert_equal 1, source.scan(original).size, "the seed must edit exactly one place: #{original}"
    File.write(path, source.sub(original, replacement))
  end

  # Writes erx/abi.h and generated/erx_abi.hrl from the copy's ABI files; returns the schema.
  def generate
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: @directory))
    { 'include/erx/abi.h' => Erx::ABI::CEmitter.header(schema),
      'include/generated/erx_abi.hrl' => Erx::ABI::ErlangEmitter.header(schema) }.each do |relative, text|
      FileUtils.mkdir_p(File.dirname(File.join(@directory, relative)))
      File.write(File.join(@directory, relative), text)
    end
    schema
  end

  def macros = SHARED.map { |name| "ERX_#{name.upcase}" }

  def c_values
    probe = File.join(@directory, 'probe.c')
    binary = File.join(@directory, 'probe')
    File.write(probe, <<~C)
      #include <inttypes.h>
      #include <stdio.h>
      #include "erx/abi.h"

      int
      main(void)
      {
      #{macros.map { |macro| "\tprintf(\"%\" PRIu64 \"\\n\", (uint64_t)#{macro});" }.join("\n")}
      \treturn (0);
      }
    C
    capture(COMPILER, '-std=c17', '-Wall', '-Werror', '-I', File.join(@directory, 'include'), probe, '-o', binary)
    capture(binary).lines.map(&:to_i)
  end

  def erlang_values
    File.write(File.join(@directory, 'abi_limits_probe.erl'), <<~ERLANG)
      -module(abi_limits_probe).
      -export([main/0]).
      -include("generated/erx_abi.hrl").
      main() ->
          [io:format("~b~n", [Value]) || Value <- [#{macros.map { |macro| "?#{macro}" }.join(', ')}]],
          halt().
    ERLANG
    capture(ENV.fetch('ERX_ERLC'), '-I', File.join(@directory, 'include'), '-o', @directory,
        File.join(@directory, 'abi_limits_probe.erl'))
    capture('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', @directory,
        '-s', 'abi_limits_probe', 'main').lines.map(&:to_i)
  end

  def compile_pipe_check
    Open3.capture2e(COMPILER, '-std=c17', '-fsyntax-only', '-I', File.join(@directory, 'include'),
                    '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                    File.join(ROOT, 'liberx/erx_pipe_check.c'), stdin_data: '')
  end

  def capture(*argv)
    output, status = Open3.capture2e(*argv, stdin_data: '')
    assert status.success?, "#{argv.first}: #{output}"
    output
  end
end
