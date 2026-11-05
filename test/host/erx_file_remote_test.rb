# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# erx_file_remote is preloaded and calls only BIFs and preloaded modules (T6 of
# docs/design-tmp.md): whatever process reaches a server's path runs it, the code server
# included, and a module the code server would have to load then halts the node. xref,
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), lists the
# client's calls to other modules; each must be a BIF or name a module of the preloaded
# Makefile's list. A seeded call to lists:usort/1 must be caught.
class ErxFileRemoteTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_file_remote.erl')
  PRELOAD_MAKEFILE = File.join(ROOT, 'otp/erts/preloaded/src/Makefile')
  INCLUDES = %w[otp/lib/kernel/include erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  FID = "fid() ->\n    prim_file:erx_fid().\n"
  SEEDED_FID = "fid() ->\n    _ = lists:usort([]),\n    prim_file:erx_fid().\n"
  # Prints each call to another module as `Module Function Arity Builtin`.
  XREF = <<~ERLANG.tr("\n", ' ')
    {ok, _} = xref:start(s), ok = xref:set_default(s, [{warnings, false}, {verbose, false}]),
    {ok, _} = xref:add_module(s, "erx_file_remote.beam"), {ok, Calls} = xref:q(s, "XC"),
    [io:format("~s ~s ~b ~s~n", [M, F, A, erlang:is_builtin(M, F, A)]) || {_, {M, F, A}} <- Calls],
    halt().
  ERLANG

  def test_the_client_is_on_the_preload_list
    assert_includes preloaded, 'erx_file_remote'
  end

  def test_the_client_calls_only_bifs_and_preloaded_modules
    calls = external_calls(File.read(SOURCE))
    assert_includes calls.map(&:first), 'prim_file', 'the calls were listed'
    assert_empty forbidden(calls), forbidden(calls).map { |call| call.first(3).join(':') }.join("\n")
  end

  def test_seeded_call_to_a_module_not_preloaded_is_caught
    source = File.read(SOURCE)
    assert_equal 1, source.scan(FID).size
    calls = external_calls(source.sub(FID, SEEDED_FID))
    assert_includes forbidden(calls).map { |call| call.first(3).join(':') }, 'lists:usort:1'
  end

  private

  def preloaded
    text = File.read(PRELOAD_MAKEFILE)
    %w[PRE_LOADED_ERL_MODULES PRE_LOADED_BEAM_MODULES].flat_map do |list|
      text[/^#{list} = \\\n((?:.*\\\n)*.*\n)/, 1].split.reject { |word| word == '\\' }
    end
  end

  def forbidden(calls)
    # $M_EXPR is a call of a fun value; every fun the client calls is one it made itself.
    calls.reject do |module_name, _, _, builtin|
      builtin == 'true' || preloaded.include?(module_name) || module_name == '$M_EXPR'
    end
  end

  def external_calls(source)
    Dir.mktmpdir('erx-file-remote-xref') do |work|
      path = File.join(work, 'erx_file_remote.erl')
      File.write(path, source)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '+debug_info', *INCLUDES.flat_map { |dir| ['-I', dir] },
                                       '-o', work, path, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-eval', XREF, chdir: work, stdin_data: '')
      assert status.success?, output
      output.lines.map(&:split).select { |words| words.size == 4 }
    end
  end
end
