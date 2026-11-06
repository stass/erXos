# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# erx_file_remote is preloaded and calls only BIFs and preloaded modules (T6 of
# docs/design-tmp.md): whatever process reaches a server's path runs it, the code server
# included, and a module the code server would have to load then halts the node. The
# generated erx_9p_grammar, which checks every request it sends and every reply, is
# preloaded and held to the same rule, as is erx_path, the resolver of every path, which
# calls nothing but BIFs and the callbacks its caller hands it. xref, on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies), lists each module's calls to other modules; each must be a
# BIF or name a module of the preloaded Makefile's list. A seeded call to lists:usort/1
# must be caught.
class ErxFileRemoteTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = { 'erx_file_remote' => 'otp/erts/preloaded/src/erx_file_remote.erl',
              'erx_9p_grammar' => 'otp/erts/preloaded/src/erx_9p_grammar.erl',
              'erx_path' => 'otp/erts/preloaded/src/erx_path.erl' }
            .transform_values { |path| File.join(ROOT, path) }.freeze
  PRELOAD_MAKEFILE = File.join(ROOT, 'otp/erts/preloaded/src/Makefile')
  INCLUDES = %w[otp/lib/kernel/include erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  FID = "fid() ->\n    prim_file:erx_fid().\n"
  SEEDED_FID = "fid() ->\n    _ = lists:usort([]),\n    prim_file:erx_fid().\n"
  # Prints each call to another module as `Module Function Arity Builtin`.
  XREF = <<~ERLANG.tr("\n", ' ')
    {ok, _} = xref:start(s), ok = xref:set_default(s, [{warnings, false}, {verbose, false}]),
    [Beam] = filelib:wildcard("*.beam"),
    {ok, _} = xref:add_module(s, Beam), {ok, Calls} = xref:q(s, "XC"),
    [io:format("~s ~s ~b ~s~n", [M, F, A, erlang:is_builtin(M, F, A)]) || {_, {M, F, A}} <- Calls],
    halt().
  ERLANG

  def test_each_module_is_on_the_preload_list
    SOURCES.each_key { |name| assert_includes preloaded, name }
  end

  def test_the_client_calls_only_bifs_and_preloaded_modules
    calls = external_calls('erx_file_remote', File.read(SOURCES.fetch('erx_file_remote')))
    assert_includes calls.map(&:first), 'prim_file', 'the calls were listed'
    assert_includes calls.map(&:first), 'erx_9p_grammar', 'the client checks through the grammar'
    assert_empty forbidden(calls), forbidden(calls).map { |call| call.first(3).join(':') }.join("\n")
  end

  def test_the_grammar_calls_only_bifs_and_preloaded_modules
    calls = external_calls('erx_9p_grammar', File.read(SOURCES.fetch('erx_9p_grammar')))
    refute_empty calls, 'the calls were listed: xref lists no BIF, but the funs it calls'
    assert_empty forbidden(calls), forbidden(calls).map { |call| call.first(3).join(':') }.join("\n")
  end

  def test_the_resolver_calls_only_bifs_and_its_callbacks
    # xref lists no BIF, so the callbacks, calls of fun values, are all it may list.
    calls = external_calls('erx_path', File.read(SOURCES.fetch('erx_path')))
    assert_equal [%w[$M_EXPR $F_EXPR]], calls.map { |call| call.first(2) }.uniq
  end

  def test_seeded_call_to_a_module_not_preloaded_is_caught
    source = File.read(SOURCES.fetch('erx_file_remote'))
    assert_equal 1, source.scan(FID).size
    calls = external_calls('erx_file_remote', source.sub(FID, SEEDED_FID))
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

  def external_calls(name, source)
    xref(name, source, XREF).select { |words| words.size == 4 }
  end

  # The words of each line the script prints, on the module compiled from source.
  def xref(name, source, script)
    Dir.mktmpdir('erx-file-remote-xref') do |work|
      path = File.join(work, "#{name}.erl")
      File.write(path, source)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '+debug_info', *INCLUDES.flat_map { |dir| ['-I', dir] },
                                       '-o', work, path, stdin_data: '')
      assert status.success?, output
      File.delete(path)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-eval', script, chdir: work, stdin_data: '')
      assert status.success?, output
      output.lines.map(&:split)
    end
  end
end
