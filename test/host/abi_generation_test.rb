# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

class AbiGenerationTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    @plan = Erx::ABI::Generator.plan(root: @root)
  end

  def test_output_bytes_cannot_change_after_validation
    assert_raises(FrozenError) { @plan.files.fetch('include/erx/abi.h') << 'changed' }
    assert_raises(FrozenError) { @plan.inventory.fetch('outputs') << 'outside' }
  end

  def test_relative_root_produces_the_same_output_plan
    relative = Pathname.new(@root).relative_path_from(Pathname.new(Dir.pwd)).to_s
    assert_equal @plan.files, Erx::ABI::Generator.plan(root: relative).files
  end

  def test_invalid_complete_input_cannot_publish_a_valid_prefix
    Dir.mktmpdir('erx-abi-invalid-') do |root|
      FileUtils.mkdir_p(File.join(root, 'abi'))
      File.write(File.join(root, 'abi/erx_abi.txt'), "abi 1\nlimit valid u32 7\ninclude late.txt\n")
      File.write(File.join(root, 'abi/late.txt'), "layout malformed 1 wire_le 4 8\n  field missing no_type 0\n")
      error = assert_raises(Erx::ABI::SchemaError) do
        Erx::ABI::Generator.publish(Erx::ABI::Generator.plan(root: root, architecture: nil), root: root)
      end
      assert_match(/undefined type/, error.message)
      refute File.exist?(File.join(root, 'include'))
      refute File.exist?(File.join(root, 'abi/generated.json'))
    end
  end

  # Each call rule refuses in the validated plan, before the first write, so
  # a refused declaration leaves the published outputs byte for byte.
  def test_refused_call_declaration_leaves_published_outputs_unchanged
    Dir.mktmpdir('erx-abi-refused-') do |root|
      FileUtils.cp_r(File.join(@root, 'abi'), root)
      FileUtils.mkdir_p(File.join(root, 'tools/lib/erx'))
      FileUtils.cp(File.join(@root, 'tools/gen_abi.rb'), File.join(root, 'tools'))
      FileUtils.cp(Dir.glob(File.join(@root, 'tools/lib/erx/abi*.rb')), File.join(root, 'tools/lib/erx'))
      Erx::ABI::Generator.publish(Erx::ABI::Generator.plan(root: root), root: root)
      snapshot = Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort
                    .select { |path| File.file?(File.join(root, path)) }
                    .to_h { |path| [path, File.binread(File.join(root, path))] }
      source = File.join(root, 'abi/erx_abi.txt')
      refused = {
        'overlap' => "  arg first u64 utcb mr[0]\n  arg second u64 utcb mr[0]\n",
        'beyond' => "  arg late u64 utcb mr[63]\n",
        'refuse' => "  arg value u64 register 0\n"
      }
      refused.each do |label, members|
        rule = label == 'refuse' ? 'refuse' : 'allow'
        File.write(source, snapshot.fetch('abi/erx_abi.txt') +
                           "call refused 99\n  waits no\n  executor #{rule}\n  effects changes\n" \
                           "  charges none\n  bound records 1\n#{members}")
        assert_raises(Erx::ABI::SchemaError, label) do
          Erx::ABI::Generator.publish(Erx::ABI::Generator.plan(root: root), root: root)
        end
        current = Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort
                     .select { |path| File.file?(File.join(root, path)) }
        assert_equal snapshot.keys, current, label
        (snapshot.keys - ['abi/erx_abi.txt']).each do |path|
          assert_equal snapshot.fetch(path), File.binread(File.join(root, path)), "#{label}: #{path}"
        end
      end
    end
  end

  def test_include_control_bytes_are_refused_before_filesystem_use
    Dir.mktmpdir('erx-abi-include-') do |root|
      FileUtils.mkdir_p(File.join(root, 'abi'))
      File.write(File.join(root, 'abi/erx_abi.txt'), "abi 1\ninclude \"bad\\x00path\"\n")
      assert_raises(Erx::ABI::SchemaError) do
        Erx::ABI::Sources.read(root: root, architecture: nil)
      end
    end
  end

  def test_unordered_declaration_order_does_not_change_generated_bytes
    chunks = ["abi 1\n", "limit zeta u32 3\n", "limit alpha u64 8\n",
              "layout outer 1 wire_le 4 4\n  field value inner 0\n",
              "scalar inner u32\n"]
    schemas = [chunks, chunks.reverse].map do |entries|
      Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(
        declarations: Erx::ABI::Syntax.parse(entries.join), inputs: {}).freeze)
    end
    assert_equal Erx::ABI::CEmitter.header(schemas.first), Erx::ABI::CEmitter.header(schemas.last)
    assert_equal Erx::ABI::RubyEmitter.new(schemas.first).emit, Erx::ABI::RubyEmitter.new(schemas.last).emit
  end

  def test_preexisting_temporary_file_is_not_owned_by_publication
    Dir.mktmpdir('erx-abi-publication-') do |root|
      path = File.join(root, @plan.files.keys.first)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp-#{Process.pid}"
      File.binwrite(temporary, 'another writer owns this')
      assert_raises(Erx::ABI::SchemaError) { Erx::ABI::Generator.publish(@plan, root: root) }
      assert_equal 'another writer owns this', File.binread(temporary)
    end
  end

  def test_destination_directory_is_refused_before_any_output_is_written
    Dir.mktmpdir('erx-abi-leaf-') do |root|
      FileUtils.mkdir_p(File.join(root, 'include/erx/abi.h'))
      assert_raises(Erx::ABI::SchemaError) { Erx::ABI::Generator.publish(@plan, root: root) }
      refute File.exist?(File.join(root, 'abi/generated.json'))
    end
  end

  def test_nested_orphan_beneath_an_owned_directory_is_detected
    %w[old .old].each do |leaf|
      Dir.mktmpdir('erx-abi-nested-orphan-') do |root|
        Erx::ABI::Generator.publish(@plan, root: root)
        directory = File.join(root, 'erlang/apps/erx/src/generated', leaf)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, 'unused.erl'), 'orphan')
        assert_match(/orphan .*generated\//,
                     assert_raises(Erx::ABI::SchemaError) { Erx::ABI::Generator.check(@plan, root: root) }.message)
      end
    end
  end

  def test_non_object_inventory_is_a_domain_error
    Dir.mktmpdir('erx-abi-inventory-') do |root|
      Erx::ABI::Generator.publish(@plan, root: root)
      File.binwrite(File.join(root, 'abi/generated.json'), '[]')
      assert_raises(Erx::Error) { Erx::ABI::Generator.check(@plan, root: root) }
    end
  end

  def test_drift_rejects_missing_stale_and_orphan_outputs
    Dir.mktmpdir('erx-abi-drift-') do |root|
      Erx::ABI::Generator.publish(@plan, root: root)
      assert Erx::ABI::Generator.check(@plan, root: root)
      path = File.join(root, 'include/erx/abi.h')
      File.unlink(path)
      assert_match(/missing include\/erx\/abi.h/,
                   assert_raises(Erx::Error) { Erx::ABI::Generator.check(@plan, root: root) }.message)
      File.binwrite(path, 'stale')
      assert_match(/stale include\/erx\/abi.h/,
                   assert_raises(Erx::Error) { Erx::ABI::Generator.check(@plan, root: root) }.message)
      Erx::ABI::Generator.publish(@plan, root: root)
      orphan = File.join(root, 'liberx/backend/hosted/generated/unused.c')
      File.write(orphan, 'orphan')
      assert_match(/orphan liberx\/backend\/hosted\/generated\/unused.c/,
                   assert_raises(Erx::Error) { Erx::ABI::Generator.check(@plan, root: root) }.message)
    end
  end

  def test_inventory_path_with_nul_is_refused_before_filesystem_use
    Dir.mktmpdir('erx-abi-inventory-') do |root|
      Erx::ABI::Generator.publish(@plan, root: root)
      File.binwrite(File.join(root, 'abi/generated.json'), '{"outputs":["bad\u0000path"]}')
      assert_raises(Erx::Error) { Erx::ABI::Generator.check(@plan, root: root) }
    end
  end

  def test_strong_table_offsets_and_counts_compile
    text = <<~ABI
      abi 1
      scalar offset u32
      scalar count u32
      layout item 1 wire_le 4 4
        field value u32 0
      layout packet 1 wire_le 4 8
        field rows_off offset 0
        field rows_count count 4
      reader check packet 16
        table rows item root.rows_off root.rows_count 2 4
        order rows
    ABI
    source = Erx::ABI::SourceSet.new(declarations: Erx::ABI::Syntax.parse(text), inputs: {}).freeze
    schema = Erx::ABI::Model.validate(source)
    Dir.mktmpdir('erx-abi-strong-offset-') do |directory|
      include_dir = File.join(directory, 'include/erx')
      FileUtils.mkdir_p(include_dir)
      File.write(File.join(include_dir, 'abi.h'), Erx::ABI::CEmitter.header(schema))
      File.write(File.join(include_dir, 'abi_reader.h'), Erx::ABI::CEmitter.reader_header(schema))
      path = File.join(directory, 'reader.c')
      File.write(path, Erx::ABI::CEmitter.prefix_source(schema) + Erx::ABI::CReaderEmitter.source(schema))
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'), timeout_program: '/opt/homebrew/bin/gtimeout')
      begin
        record = runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                             '-I', File.join(directory, 'include'), '-I', File.join(@root, 'include'),
                             '-c', path, '-o', File.join(directory, 'reader.o')], name: 'strong-offset', deadline: 60)
        assert_equal 0, record.fetch('exit_status')
      rescue Erx::CommandError => error
        flunk(File.binread(error.result.fetch('log')))
      end
    end
  end
end
