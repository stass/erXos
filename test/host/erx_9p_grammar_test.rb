# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'

# The file protocol's frame profile: test/erlang/erx_9p_grammar_tests.erl, the EUnit cases
# of the generated erx_9p_grammar, run on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies) against the module the build generates and against one generated from
# a table whose name bound admits 256 bytes, which must fail; and the table's refusals of
# malformed protocol declarations.
class Erx9pGrammarTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated module the cases run against is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  GENERATED = 'otp/erts/preloaded/src/erx_9p_grammar.erl'
  TABLE = 'abi/protocols/9p.txt'
  NAME_KIND = 'text name max @name_max utf8'

  def test_grammar_cases_pass_under_eunit
    output, status = eunit(File.binread(File.join(ROOT, Erx::Generated::OUTPUT, GENERATED)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  # The emulator embeds otp/erts/preloaded/ebin/erx_9p_grammar.beam, which the
  # runtime build does not compile (TODO.md, the preloaded beams), so the
  # checked-in beam must be the generated grammar compiled as the preloaded
  # modules are: a change to the table that this test does not see in the beam
  # would be tested here and never shipped.
  def test_the_preloaded_beam_is_the_generated_grammar_compiled
    Dir.mktmpdir('erx-9p-grammar-beam') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '+nowarn_deprecated_catch', '+deterministic', '-o', work,
                                       File.join(ROOT, Erx::Generated::OUTPUT, GENERATED), stdin_data: '')
      assert status.success?, output
      assert_equal File.binread(File.join(ROOT, 'otp/erts/preloaded/ebin/erx_9p_grammar.beam')),
                   File.binread(File.join(work, 'erx_9p_grammar.beam')),
                   'recompile otp/erts/preloaded/ebin/erx_9p_grammar.beam from the generated grammar'
    end
  end

  def test_a_table_that_drops_the_name_bound_fails_the_cases
    source = with_table(->(text) { text.sub(NAME_KIND, 'text name max 256 utf8') }) do |root|
      schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
      Erx::ABI::ProtocolEmitter.outputs(schema).fetch(GENERATED)
    end
    output, status = eunit(source)
    refute status.success?, output
    assert_match(/name_test/, output)
  end

  def test_malformed_protocol_declarations_are_refused
    {
      '  colour blue' => /unknown protocol member colour/,
      '  integer spare u32 max 1' => /unused kinds spare/,
      '  integer utf8 u32 max 1' => /reserved kind name utf8/,
      '  integer a.b u32 max 1' => /not a plain Erlang atom/,
      '  integer q u64 or end' => /not a plain Erlang atom/,
      "  operation error 201\n    request fid u32" => /cannot be named error/,
      '  text huge max 65536' => /outside 0\.\.65535/,
      '  text huge max 65537 length u32' => /outside 0\.\.65536/,
      "  operation clunk2 120\n    request fid u32" => /duplicate operation type/,
      "  operation odd 200\n    request fid u32\n    reply data u8\n    check data.length le fid.value" =>
        /measure length does not apply to data/,
      "  operation odd 200\n    request fid u32\n    refused\n    reply qid u64" => /refused operation has no reply/
    }.each do |addition, message|
      error = assert_raises(Erx::Error) do
        with_table(->(text) { text.sub("protocol erx_9p\n", "protocol erx_9p\n#{addition}\n") }) do |root|
          Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
        end
      end
      assert_match(message, error.message, addition)
    end
  end

  # Every request field of kind fid states what its fid names, so an operation
  # cannot be added whose directory fid goes unchecked by omission. Operations go
  # at the end of the table, after the kinds they name.
  def test_malformed_fid_fields_are_refused
    {
      "  operation odd 200\n    request fid fid" => /field fid of kind fid states what it names: directory, node or new/,
      "  operation odd 200\n    request fid fid dir" => /unknown field attribute dir/,
      "  operation odd 200\n    request fid fid node directory" => /a field has at most one attribute/,
      "  operation odd 200\n    request fid fid node\n    reply other fid node new" => /a field has at most one attribute/,
      "  operation odd 200\n    request Bad fid node new" => /invalid identifier "Bad"/,
      "  operation odd 200\n    request name name directory" => /only a field of kind fid takes an attribute, not name/,
      "  operation odd 200\n    request name name node" => /only a field of kind fid takes an attribute, not name/,
      "  operation odd 200\n    request fid fid node\n    reply other fid new" => /only a request field takes an attribute/
    }.each do |addition, message|
      error = assert_raises(Erx::Error) do
        with_table(->(text) { "#{text}#{addition}\n" }) do |root|
          Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
        end
      end
      assert_match(message, error.message, addition)
    end
  end

  def test_a_directory_field_is_listed_by_directory_fids
    source = with_table(->(text) { "#{text}  operation odd 200\n    request fid fid node\n    request at_fid fid directory\n    request new_fid fid new\n" }) do |root|
      Erx::ABI::ProtocolEmitter.outputs(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))).fetch(GENERATED)
    end
    assert_includes source, "directory_fids({odd, _, AtFid, _}) ->\n    [AtFid]"
  end

  # directory_fids/1 answers for every operation the table declares and for nothing
  # else: a clause per operation, and none that matches any request.
  def test_directory_fids_has_a_clause_per_operation_and_no_catch_all
    source = File.binread(File.join(ROOT, Erx::Generated::OUTPUT, GENERATED))
    protocol = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)).protocols.first
    clauses = source.scan(/^directory_fids\(\{(\w+)[,}]/).flatten
    assert_equal protocol.fetch(:operations).map { |operation| operation.fetch(:name) }.sort, clauses.sort
    refute_match(/^directory_fids\([^{]/, source)
    assert_includes source, "directory_fids({renameat, OldDirFid, _, NewDirFid, _}) ->\n    [OldDirFid, NewDirFid]"
    assert_includes source, "directory_fids({walk, _, _, _}) ->\n    []"
  end

  def test_fields_that_share_a_variable_are_refused
    error = assert_raises(Erx::Error) do
      with_table(->(text) { text.sub("protocol erx_9p\n", "protocol erx_9p\n  operation odd 200\n    request a_1 u32\n    request a1 u32\n") }) do |root|
        Erx::ABI::ProtocolEmitter.outputs(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root)))
      end
    end
    assert_match(/odd has fields that share an Erlang variable/, error.message)
  end

  private

  # A copy of abi/ whose protocol table is edited.
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

  def eunit(module_text)
    Dir.mktmpdir('erx-9p-grammar-test') do |work|
      module_path = File.join(work, 'erx_9p_grammar.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, module_path,
                                       File.join(ROOT, 'test/erlang/erx_9p_grammar_tests.erl'), stdin_data: '')
      assert status.success?, output
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_9p_grammar_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
