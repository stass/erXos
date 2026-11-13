# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'

# The file protocol's 9P2000.L codec: test/erlang/erx_9p_tests.erl, the EUnit cases of
# the generated erx_9p, run on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies) with the generated grammar beside it, against the module the build generates
# and against one generated from a table that gives ENOENT another number, which must
# fail; and the table's refusals of malformed error lists and wire options.
class Erx9pTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  # Generated files, by the paths the generator names them; build/gen holds them there.
  CODEC = 'erlang/apps/erx/src/generated/erx_9p.erl'
  # The grammar is a module of the preloaded set, not of an application, so the suite compiles it
  # beside the codec, which the applications hold as ErlangApps spells it.
  GRAMMAR = File.join(Erx::Generated::OUTPUT, 'otp/erts/preloaded/src/erx_9p_grammar.erl')
  BUILT_CODEC = File.join(Erx::Generated::OUTPUT, CODEC)
  APPLICATIONS = %w[erx].freeze
  TESTS = [GRAMMAR, 'test/erlang/erx_9p_tests.erl'].freeze
  TABLE = 'abi/protocols/9p.txt'

  def test_codec_cases_pass_under_eunit
    output, status = eunit(File.binread(File.join(ROOT, BUILT_CODEC)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_table_with_a_wrong_error_number_fails_the_cases
    source = with_table(->(text) { text.sub("    error enoent 2\n", "    error enoent 3\n") }) do |root|
      schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
      Erx::ABI::WireEmitter.outputs(schema).fetch(CODEC)
    end
    output, status = eunit(source)
    refute status.success?, output
    assert_match(/lerror_test/, output)
  end

  def test_malformed_errors_and_wire_options_are_refused
    {
      ->(text) { text.sub('  errors type @p9_rlerror', '  errors') } => /expected errors type N/,
      ->(text) { text.sub('    error enoent 2', '    error enoent 13') } => /duplicate error number/,
      ->(text) { text.sub('    error enoent 2', '    error eacces 2') } => /duplicate error atom/,
      ->(text) { text.sub('    error enoent 2', '    error enoent 0') } => /error number is not 0/,
      ->(text) { text.sub('    error enoent 2', '    enoent 2') } => /expected error ATOM NUMBER/,
      ->(text) { text.sub('  errors type @p9_rlerror', '  errors type 13') } => /message types .* collide/,
      ->(text) { text.sub('  operation statfs 8', '  operation statfs 9') } => /request type is even/,
      ->(text) { text.sub('  operation statfs 8', '  operation reply 8') } => /cannot be named reply/,
      ->(text) { text.sub('  integer fid u32 except @p9_nofid', '  integer fid u32 except @p9_nofid local') } =>
        /only an integer with or ATOM may be local/,
      ->(text) { text.sub('  text data max @p9_io_max length u32', '  text data max @p9_io_max') } =>
        /kind data: max past its u16 length/,
      ->(text) { text.sub('  text data max @p9_io_max length u32', '  text data max @p9_io_max length u8') } =>
        /length u16 or u32/
    }.each do |edit, message|
      error = assert_raises(Erx::Error) do
        with_table(edit) { |root| Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root)) }
      end
      assert_match(message, error.message)
    end
  end

  # An integer kind with "or ATOM" that 9P2000.L carried would have no bytes for its atom.
  def test_a_wire_kind_with_an_atom_must_be_local
    error = assert_raises(Erx::Error) do
      with_table(->(text) { text.sub('  integer at u64 or unknown local', '  integer at u64 or unknown') }) do |root|
        Erx::ABI::WireEmitter.outputs(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root)))
      end
    end
    assert_match(/no 9P2000\.L form for unknown/, error.message)
  end

  # A local kind inside a tuple would drop bytes from the middle of the wire form, and an
  # unpacked list's u16 count would wrap past 65535 elements.
  def test_wire_layouts_that_lose_bytes_are_refused
    {
      ->(text) { text.sub('  tuple qid u8 u32 u64', '  tuple qid u8 u32 at') } => /holds the local kind at/,
      ->(text) { text.sub('  list walk_names walk_name max @p9_maxwelem', '  list walk_names walk_name max 65536') } =>
        /counts its elements in a u16/
    }.each do |edit, message|
      error = assert_raises(Erx::Error) do
        with_table(edit) { |root| Erx::ABI::WireEmitter.outputs(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))) }
      end
      assert_match(message, error.message)
    end
  end

  private

  def with_table(edit)
    Dir.mktmpdir('erx-9p-table-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, TABLE)
      edited = edit.call(File.binread(path))
      refute_equal File.binread(path), edited, 'the edit must change the table'
      File.binwrite(path, edited)
      yield root
    end
  end

  def eunit(codec_text)
    Dir.mktmpdir('erx-9p-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { BUILT_CODEC => codec_text })
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_9p_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
