# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/preload_calls'

# The preloaded modules' rule (Erx::PreloadCalls): a preloaded module erXos wrote calls
# only BIFs and preloaded modules' functions, read from the import tables of beams the
# stock compiler (ERX_ERLC) makes, against the tree's own preload list and bif.tab.
class PreloadCallsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'otp')

  def setup
    @directory = Dir.mktmpdir('preload-calls')
    @otp = File.join(@directory, 'otp')
    @ebin = File.join(@directory, 'ebin')
    [Erx::PreloadCalls::MAKEFILE, Erx::PreloadCalls::BIF_TABLE].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@otp, path)))
      FileUtils.cp(File.join(OTP, path), File.join(@otp, path))
    end
    FileUtils.mkdir_p(@ebin)
  end

  def teardown = FileUtils.rm_rf(@directory)

  # A beam in ebin of each preloaded module whose body calls: a BIF, a preloaded
  # module's function and an erlang: one, or for a module `extra` names, its body there.
  def preloaded_beams(extra: {})
    sources = Erx::PreloadCalls.modules(File.read(File.join(@otp, Erx::PreloadCalls::MAKEFILE))).map do |name|
      body = extra.fetch(name, "f(L) -> {lists:member(a, L), erx_facets:find(L), erlang:length(L)}.\n")
      File.join(@directory, "#{name}.erl").tap { |source| File.write(source, "-module(#{name}).\n-export([f/1]).\n#{body}") }
    end
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-o', @ebin, *sources,
                                     stdin_data: '')
    assert status.success?, output
  end

  def enforce = Erx::PreloadCalls.enforce!(otp: @otp, ebin: @ebin)

  def test_bifs_and_preloaded_functions_pass
    preloaded_beams
    enforce
  end

  def test_a_stdlib_call_in_an_erxos_preloaded_module_is_refused
    preloaded_beams(extra: { 'erx_path' => "f(L) -> lists:sort(L).\n" })
    error = assert_raises(Erx::PreloadCalls::Refused) { enforce }
    assert_includes error.message, 'erx_path calls lists:sort/1'
    assert_includes error.message, 'cannot get bootfile'
  end

  # The arity is the import's: lists:reverse/2 is a BIF, lists:reverse/1 stdlib's.
  def test_the_arity_decides
    preloaded_beams(extra: { 'erx_facets' => "f(L) -> {lists:reverse(L, []), lists:reverse(L)}.\n" })
    error = assert_raises(Erx::PreloadCalls::Refused) { enforce }
    assert_includes error.message, 'erx_facets calls lists:reverse/1'
    refute_includes error.message, 'lists:reverse/2'
  end

  # A call the reviewed list allows one module is refused in another.
  def test_a_reviewed_call_is_allowed_only_its_module
    preloaded_beams(extra: { 'erx_program' => "f(L) -> lists:sort(L).\n", 'erx_path' => "f(L) -> lists:sort(L).\n" })
    error = assert_raises(Erx::PreloadCalls::Refused) { enforce }
    assert_includes error.message, 'erx_path calls lists:sort/1'
    refute_includes error.message, 'erx_program'
  end

  # Stock modules are not bound: init calls kernel and stdlib once the boot loaded them.
  def test_a_stock_preloaded_module_is_not_bound
    preloaded_beams(extra: { 'init' => "f(L) -> lists:sort(L).\n" })
    enforce
  end
end
