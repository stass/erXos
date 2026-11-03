# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/abi_model'
require_relative '../../tools/lib/erx/abi_emit_c'
require_relative '../../tools/lib/erx/abi_emit_reader'
require_relative '../../tools/lib/erx/runner'
require 'tmpdir'
require 'fileutils'

class AbiSchemaTest < Minitest::Test
  def schema(body, architecture: nil)
    text = "abi 1\n#{body}"
    declarations = Erx::ABI::Syntax.parse(text, path: 'abi/erx_abi.txt')
    inputs = { 'abi/erx_abi.txt' => text.freeze }
    if architecture
      path = 'abi/arch/aarch64.txt'
      declarations += Erx::ABI::Syntax.parse(architecture, path: path)
      inputs[path] = architecture.freeze
    end
    source = Erx::ABI::SourceSet.new(declarations: declarations.freeze,
                                    inputs: inputs.freeze).freeze
    Erx::ABI::Model.validate(source)
  end

  def call_source(parameters)
    <<~ABI
      call inspect 1
        waits no
        executor allow
        effects reads
        charges none
        bound records 1
      #{parameters}
    ABI
  end

  def architecture
    <<~ABI
      arch aarch64
      trap svc 0x4552
      reg number x8
      reg args x0,x1,x2,x3,x4,x5
      reg results x0,x1,x2
      reg preserved x3,x4,x5,x6,x7,x8,x9,x10,x11,x12,x13,x14,x15,x16,x17,x18,x19,x20,x21,x22,x23,x24,x25,x26,x27,x28,x29,x30
    ABI
  end

  def test_valid_fixed_layout_keeps_offsets
    model = schema("layout sample 1 wire_le 8 16\n  field first u64 0\n  field second u32 8\n  padding 12 4\n")
    layout = model.types.fetch('sample')
    assert_equal 16, layout.size
    assert_equal [0, 8], layout.fields.map(&:offset)
  end

  def test_emitter_prefix_normalization_cannot_merge_constants
    assert_raises(Erx::ABI::SchemaError) do
      schema("limit foo u32 1\nlimit erx_foo u32 2\n")
    end
  end

  def test_constant_cannot_replace_a_generated_layout_alignment
    assert_raises(Erx::ABI::SchemaError) do
      schema("limit sample_align u32 16\nlayout sample 1 wire_le 8 8\n  field value u64 0\n")
    end
  end

  def test_source_type_cannot_replace_builtin_status_type
    assert_raises(Erx::ABI::SchemaError) { schema("scalar status u64\n") }
  end

  def test_constants_cannot_disable_generated_header_guards
    assert_raises(Erx::ABI::SchemaError) { schema("limit abi_hrl u32 1\n") }
  end

  def test_call_shape_types_share_the_emitted_symbol_inventory
    assert_raises(Erx::ABI::SchemaError) do
      schema("scalar sys_inspect_args u64\n" + call_source('  arg value u64 register 0'),
             architecture: architecture)
    end
  end

  def test_call_arguments_cannot_shadow_trap_local_bindings
    %w[x0 status raw_status].each do |name|
      assert_raises(Erx::ABI::SchemaError) do
        schema(call_source("  arg #{name} u64 register 0"), architecture: architecture)
      end
    end
  end

  def test_reader_helpers_share_the_emitted_symbol_inventory
    assert_raises(Erx::ABI::SchemaError) do
      schema("layout abi_fail 1 wire_le 4 4\n  field value u32 0\n")
    end
  end

  def test_by_value_depth_is_bounded_before_emission
    body = "layout level0 1 wire_le 1 1\n  field byte u8 0\n"
    65.times do |index|
      body += "layout level#{index + 1} 1 wire_le 1 1\n  field inner level#{index} 0\n"
    end
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_guard_requires_a_known_scalar_tag_in_the_same_record
    source = <<~ABI
      enum kind u32
        value selected 1
      layout packet 1 wire_le 4 8
        field tag kind 0
        field value u32 4
      reader check packet 8
        range root.value 0 1 when root.tag missing
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(source) }
    valid = schema(source.sub('root.tag missing', 'root.tag selected'))
    assert_equal 1, valid.readers.first.rules.first.fetch(:guard).fetch(:value)
  end

  def test_layout_members_are_local_identifiers
    assert_raises(Erx::ABI::SchemaError) do
      schema("layout sample 1 wire_le 8 8\n  field parent.child u64 0\n")
    end
  end

  def test_c_keyword_cannot_name_a_field
    assert_raises(Erx::ABI::SchemaError) do
      schema("layout sample 1 wire_le 8 8\n  field return u64 0\n")
    end
  end

  def test_enum_constants_cannot_overwrite_explicit_limits
    assert_raises(Erx::ABI::SchemaError) do
      schema("limit mode_read u32 9\nenum mode u32\n  value read 1\n")
    end
  end

  def test_result_cannot_use_an_argument_only_register
    assert_raises(Erx::ABI::SchemaError) do
      schema(call_source('  result value u64 register 5'), architecture: architecture)
    end
  end

  def test_utcb_fields_cannot_overlap
    assert_raises(Erx::ABI::SchemaError) do
      schema(call_source("  arg whole u64 utcb 0\n  arg half u32 utcb 4"), architecture: architecture)
    end
  end

  def test_architecture_rejects_a_nonexistent_register
    assert_raises(Erx::ABI::SchemaError) do
      schema('', architecture: architecture.sub('reg number x8', 'reg number mystery'))
    end
  end

  def test_architecture_cannot_preserve_written_result
    assert_raises(Erx::ABI::SchemaError) do
      schema('', architecture: architecture.sub('reg preserved x3', 'reg preserved x0,x3'))
    end
  end

  def test_call_requires_an_architecture_binding
    assert_raises(Erx::ABI::SchemaError) { schema(call_source('  arg value u32 register 0')) }
  end

  def test_shipped_sources_form_a_complete_valid_model
    root = File.expand_path('../..', __dir__)
    model = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    assert_equal 64, model.types.fetch('erx_pack_header').size
    assert_equal 368, model.types.fetch('erx_manifest').size
  end

  def test_nested_projection_cannot_hide_development_leaf
    body = <<~ABI
      layout inner 1 wire_le 8 8
        field secret u64 0
        visibility secret development
      layout outer 1 wire_le 8 8
        field inner inner 0
      projection public_view outer release
        show inner
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_public_projection_requires_explicit_leaf_visibility
    body = "layout sample 1 wire_le 8 8\n  field value u64 0\nprojection public_view sample release\n  show value\n"
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_input_role_covers_nested_fields
    body = <<~ABI
      layout inner 1 wire_le 4 4
        field tag u32 0
        owner tag caller all
        input_mask tag caller all
      layout outer 1 wire_le 4 4
        field inner inner 0
      reader check outer 4
        source stranger
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_service_interface_numbers_are_unique
    assert_raises(Erx::ABI::SchemaError) { schema("service first 1\nservice second 1\n") }
  end

  def test_wire_layout_cannot_embed_native_storage
    body = <<~ABI
      layout inner 1 native 8 8
        field value u64 0
      layout outer 1 wire_le 8 8
        field inner inner 0
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_reader_requires_wire_storage
    body = "layout sample 1 native 8 8\n  field value u64 0\nreader check sample 8\n"
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_explicit_one_element_array_keeps_its_array_type
    body = <<~ABI
      layout sample 1 shared 8 8
        field ready u64 0 count 1
        atomic ready[] load acquire store release
        writer ready[] kernel
        owner ready[] kernel all
        visibility ready[] release
    ABI
    model = schema(body)
    assert_includes Erx::ABI::CEmitter.header(model), 'ready[1]'
  end

  def test_short_capability_argument_is_a_schema_error
    body = <<~ABI
      scalar cap u64
      type memory 1
        rights none
        default none
        pass none
      #{call_source('  arg target cap memory')}
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body, architecture: architecture) }
  end

  def test_signed_value_reference_is_not_treated_as_an_offset
    body = <<~ABI
      limit expected i32 -1
      layout sample 1 wire_le 4 4
        field value i32 0
      reader check sample 4
        value root.value @expected
    ABI
    model = schema(body)
    assert_equal [-1], model.readers.first.rules.first.fetch(:values)
  end

  def test_abi_version_is_available_to_reader_constraints
    body = <<~ABI
      layout sample 1 wire_le 4 4
        field version u32 0
      reader check sample 4
        value root.version @abi_version
    ABI
    assert_equal [1], schema(body).readers.first.rules.first.fetch(:values)
  end

  def test_reader_path_components_are_immutable
    body = "layout sample 1 wire_le 4 4\n  field version u32 0\nreader check sample 4\n  value root.version 1\n"
    path = schema(body).readers.first.rules.first.fetch(:path)
    assert path.fields.first.frozen?
  end

  def test_source_parser_does_not_freeze_caller_path
    path = +'abi/fixture.txt'
    Erx::ABI::Syntax.parse("abi 1\n", path: path)
    refute path.frozen?
  end

  def test_whole_reader_rejects_tail_root_without_a_tail_consumer
    body = <<~ABI
      layout item 1 wire_le 4 4
        field value u32 0
      layout packet 1 wire_le 4 4
        field count u32 0
        tail items item count 8
      reader packet_reader packet 36
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_whole_reader_rejects_nested_record_arrays_without_a_consumer
    body = <<~ABI
      flags options u32
        bit enabled 0
      layout item 1 wire_le 4 4
        field flags options 0
      layout packet 1 wire_le 4 8
        field items item 0 count 2
      reader packet_reader packet 8
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_debug_log_is_bounded_by_utcb_message_bytes
    root = File.expand_path('../..', __dir__)
    model = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    argument = model.calls.fetch('debug_log').fetch(:arguments).first
    assert_equal 504, argument.fetch(:type).maximum
    assert_equal 504, model.calls.fetch('debug_log').fetch(:bounds).fetch('bytes')
  end

  def test_tail_members_cannot_use_c_keywords
    body = "layout packet 1 wire_le 4 4\n  field count u32 0\n  tail return u32 count 8\n"
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_reader_table_names_are_local_and_cannot_replace_root_scope
    ['qualified.table', 'root'].each do |name|
      body = <<~ABI
        layout item 1 wire_le 4 4
          field value u32 0
        layout packet 1 wire_le 4 8
          field offset u32 0
          field count u32 4
        reader check packet 12
          table #{name} item root.offset root.count 1 4
          order #{name}
      ABI
      assert_raises(Erx::ABI::SchemaError) { schema(body) }
    end
  end

  def test_qualified_reader_name_compiles_with_its_validated_c_spelling
    model = schema("layout packet 1 wire_le 4 4\n  field value u32 0\nreader example.reader packet 4\n")
    compile_reader(model)
  end

  def test_tableless_reader_rejects_unknown_order_entries
    body = "layout packet 1 wire_le 4 4\n  field value u32 0\nreader check packet 4\n"
    assert_empty schema(body).readers.first.order
    error = assert_raises(Erx::ABI::SchemaError) { schema(body + "  order absent\n") }
    assert_includes error.message, 'table order must name every table exactly once'
  end

  def test_string_table_only_reader_compiles
    model = schema(<<~ABI)
      layout packet 1 wire_le 4 8
        field offset u32 0
        field size u32 4
      reader check packet 16
        string_table text root.offset root.size 8
        order text
    ABI
    compile_reader(model)
  end

  def compile_reader(model)
    root = File.expand_path('../..', __dir__)
    Dir.mktmpdir('erx-reader-name-') do |directory|
      include_root = File.join(directory, 'include')
      FileUtils.mkdir_p(File.join(include_root, 'erx'))
      File.binwrite(File.join(include_root, 'erx/abi.h'), Erx::ABI::CEmitter.header(model))
      File.binwrite(File.join(include_root, 'erx/abi_reader.h'), Erx::ABI::CEmitter.reader_header(model))
      source = File.join(directory, 'reader.c')
      File.binwrite(source, Erx::ABI::CEmitter.prefix_source(model) + Erx::ABI::CReaderEmitter.source(model))
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      result = runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror',
                           '-pedantic', '-I', include_root, '-I', File.join(root, 'include'),
                           '-c', source, '-o', File.join(directory, 'reader.o')],
                          name: 'compile-qualified-reader', deadline: 30)
      assert_equal 0, result.fetch('exit_status')
    rescue Erx::CommandError => error
      flunk(File.binread(error.result.fetch('log')))
    end
  end
end
