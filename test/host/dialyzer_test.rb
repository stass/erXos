# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/dialyzer'

# The Dialyzer step of `make check` fails on what it exists to catch: a call that
# breaks a type, and a spec its function does not meet. A PLT of one library module and
# the tree's erlang.erl, which every module calls (module_info/0), stands in for the
# tree's OTP, built and reused as the step builds and reuses the real one.
class DialyzerTest < Minitest::Test
  SourceSet = Erx::Dialyzer::SourceSet
  ERLANG = File.expand_path('../../otp/erts/preloaded/src/erlang.erl', __dir__)

  # name/1 also takes an integer, which its spec does not admit: a call with one breaks
  # the contract, not the success typing.
  LIBRARY = <<~ERLANG
    -module(library).
    -export([name/1]).
    -spec name(atom()) -> string().
    name(Atom) when is_atom(Atom) -> atom_to_list(Atom);
    name(Integer) -> integer_to_list(Integer).
  ERLANG

  def setup
    @root = File.realpath(Dir.mktmpdir('erx-dialyzer-'))
    runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    @dialyzer = Erx::Dialyzer.new(root: @root, runner: runner, erlc: ENV.fetch('ERX_ERLC'))
    @plt = @dialyzer.plt(library)
  end

  def library(text = LIBRARY) = set('library.erl' => text, 'erlang.erl' => File.read(ERLANG))

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def set(sources)
    sources.each { |name, text| File.write(File.join(@root, name), text) }
    SourceSet.new(files: sources.keys, includes: [], defines: {})
  end

  def analyse(name, text) = @dialyzer.analyse(plt: @plt, set: set(name => text))

  def test_code_that_meets_the_library_s_types_passes
    analyse('greeter.erl', <<~ERLANG)
      -module(greeter).
      -export([greeting/0]).
      -spec greeting() -> string().
      greeting() -> library:name(hello).
    ERLANG
  end

  def test_a_call_that_breaks_the_library_s_spec_fails
    error = assert_raises(Erx::Error) do
      analyse('greeter.erl', <<~ERLANG)
        -module(greeter).
        -export([greeting/0]).
        greeting() -> library:name(42).
      ERLANG
    end
    assert_match(/\Adialyzer: Dialyzer warned; log: /, error.message)
    assert_match(/breaks the contract/, File.read(error.message[/log: (\S+)/, 1]))
  end

  def test_a_spec_its_function_does_not_meet_fails
    error = assert_raises(Erx::Error) do
      analyse('greeter.erl', <<~ERLANG)
        -module(greeter).
        -export([count/0]).
        -spec count() -> integer().
        count() -> none.
      ERLANG
    end
    assert_match(/Invalid type specification/, File.read(error.message[/log: (\S+)/, 1]))
  end

  def test_a_plt_of_the_same_inputs_is_reused_and_one_of_new_inputs_replaces_it
    built = File.mtime(@plt)
    assert_equal @plt, @dialyzer.plt(library)
    assert_equal built, File.mtime(@plt)

    changed = @dialyzer.plt(library(LIBRARY.sub('atom()', 'atom() | integer()')))
    refute_equal @plt, changed
    assert_equal [changed], Dir.glob(File.join(@root, Erx::Dialyzer::OUTPUT, 'plt-*'))
  end

  # A checkout whose build/ links elsewhere: the step refuses the link before it
  # removes anything, so what the link reaches keeps its files.
  def test_an_output_path_that_crosses_a_link_is_refused_before_anything_is_removed
    checkout = File.join(@root, 'checkout')
    outside = File.join(@root, 'outside')
    kept = %w[ebin public_key].map { |name| File.join(outside, 'dialyzer', name, 'kept') }
    kept.each { |file| FileUtils.mkdir_p(File.dirname(file)) && File.write(file, '') }
    FileUtils.mkdir_p(checkout)
    File.symlink(outside, File.join(checkout, 'build'))
    runner = Erx::Runner.new(owner_root: checkout, log_dir: File.join(checkout, 'logs'))
    dialyzer = Erx::Dialyzer.new(root: checkout, runner: runner, erlc: ENV.fetch('ERX_ERLC'))

    assert_match(/symbolic link/, assert_raises(Erx::Error) { dialyzer.plt(SourceSet.new(files: [], includes: [], defines: {})) }.message)
    assert_match(/symbolic link/, assert_raises(Erx::Error) { dialyzer.generate }.message)
    kept.each { |file| assert File.file?(file), "#{file} was removed" }
  end
end
