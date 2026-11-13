# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../fixtures/sanitizer_environment'

class AbiGenerationTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    @plan = Erx::ABI::Generator.plan(root: @root)
  end

  def test_output_bytes_cannot_change_after_validation
    assert_raises(FrozenError) { @plan.files.fetch('include/erx/abi.h') << 'changed' }
  end

  def test_relative_root_produces_the_same_output_plan
    relative = Pathname.new(@root).relative_path_from(Pathname.new(Dir.pwd)).to_s
    assert_equal @plan.files, Erx::ABI::Generator.plan(root: relative).files
  end

  # A schema error anywhere in the complete input refuses the whole plan, so
  # nothing of a valid prefix reaches the generated tree.
  def test_invalid_complete_input_refuses_the_whole_plan
    Dir.mktmpdir('erx-abi-invalid-') do |root|
      FileUtils.mkdir_p(File.join(root, 'abi'))
      File.write(File.join(root, 'abi/erx_abi.txt'), "abi 1\nlimit valid u32 7\ninclude late.txt\n")
      File.write(File.join(root, 'abi/late.txt'), "layout malformed wire_le 4 8\n  field missing no_type 0\n")
      error = assert_raises(Erx::ABI::SchemaError) { Erx::ABI::Generator.plan(root: root, architecture: nil) }
      assert_match(/undefined type/, error.message)
    end
  end

  # Each call rule refuses in the validated plan, before anything is written.
  def test_refused_call_declarations_refuse_the_plan
    Dir.mktmpdir('erx-abi-refused-') do |root|
      FileUtils.cp_r(File.join(@root, 'abi'), root)
      source = File.join(root, 'abi/erx_abi.txt')
      original = File.binread(source)
      refused = {
        'overlap' => "  arg first u64 utcb mr[0]\n  arg second u64 utcb mr[0]\n",
        'beyond' => "  arg late u64 utcb mr[63]\n",
        'refuse' => "  arg value u64 register 0\n"
      }
      refused.each do |label, members|
        rule = label == 'refuse' ? 'refuse' : 'allow'
        File.write(source, original +
                           "call refused 99\n  waits no\n  executor #{rule}\n  effects changes\n" \
                           "  charges none\n  bound records 1\n#{members}")
        assert_raises(Erx::ABI::SchemaError, label) { Erx::ABI::Generator.plan(root: root) }
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
              "layout outer wire_le 4 4\n  field value inner 0\n",
              "scalar inner u32\n"]
    schemas = [chunks, chunks.reverse].map do |entries|
      Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(
        declarations: Erx::ABI::Syntax.parse(entries.join), inputs: {}).freeze)
    end
    assert_equal Erx::ABI::CEmitter.header(schemas.first), Erx::ABI::CEmitter.header(schemas.last)
    assert_equal Erx::ABI::RubyEmitter.new(schemas.first).emit, Erx::ABI::RubyEmitter.new(schemas.last).emit
  end

  def test_strong_table_offsets_and_counts_compile
    text = <<~ABI
      abi 1
      scalar offset u32
      scalar count u32
      layout item wire_le 4 4
        field value u32 0
      layout packet wire_le 4 8
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
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'), timeout_program: 'gtimeout')
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
  # A member without an args line has an empty argument list, which C17
  # cannot spell as an empty initializer: the lookup still builds.
  def test_event_without_arguments_compiles
    text = <<~ABI
      abi 1
      enum ev u32
        value park 1
        value wake 2
        args park slot:u64
      layout rec wire_le 8 16
        field event u32 0
        padding 4 4
        field arg u64 8 count 1
        names event ev args arg
    ABI
    source = Erx::ABI::SourceSet.new(declarations: Erx::ABI::Syntax.parse(text), inputs: {}).freeze
    header = Erx::ABI::CEmitter.header(Erx::ABI::Model.validate(source))
    assert_includes header, '[ERX_EV_WAKE] = { .name = "wake", .nargs = 0 },'
    Dir.mktmpdir('erx-abi-noargs-') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'erx'))
      File.write(File.join(directory, 'erx/abi.h'), header)
      File.write(File.join(directory, 'use.c'), "#include <erx/abi.h>\nconst erx_abi_event_t *use(void) { return (erx_ev_describe(2)); }\n")
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'), timeout_program: 'gtimeout')
      begin
        runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-ffreestanding', '-I', directory,
                    '-fsyntax-only', File.join(directory, 'use.c')], name: 'noargs', deadline: 60)
      rescue Erx::CommandError => error
        flunk(File.binread(error.result.fetch('log')))
      end
    end
  end

  # An enum's name lookup gives each member's name as the ABI file
  # spells it, NULL for a value the enum does not hold, and its longest
  # name's length; a flags type gets none. In the tree, the display
  # policy's names are the words of a display domain's display_policy.
  def test_enum_name_lookup_spells_each_member
    text = <<~ABI
      abi 1
      enum ev u32
        value park 1
        value wake_up 3
      flags fl u32
        bit one 0
    ABI
    source = Erx::ABI::SourceSet.new(declarations: Erx::ABI::Syntax.parse(text), inputs: {}).freeze
    header = Erx::ABI::CEmitter.header(Erx::ABI::Model.validate(source))
    refute_includes header, 'erx_fl_name('
    program = <<~C
      #include <stdio.h>
      #include <erx/abi.h>

      int
      main(void)
      {
      	for (uint32_t value = 0; value <= 4; value++)
      		printf("%u %s\\n", value, erx_ev_name(value) == NULL ? "unknown" : erx_ev_name(value));
      	printf("max %d\\n", ERX_EV_NAME_MAX);
      	return (0);
      }
    C
    Dir.mktmpdir('erx-abi-names-') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'erx'))
      File.write(File.join(directory, 'erx/abi.h'), header)
      File.write(File.join(directory, 'names.c'), program)
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'), timeout_program: 'gtimeout')
      begin
        runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I', directory,
                    '-o', File.join(directory, 'names'), File.join(directory, 'names.c')], name: 'build', deadline: 60)
        record = runner.run([File.join(directory, 'names')], name: 'names', deadline: 60)
      rescue Erx::CommandError => error
        flunk(File.binread(error.result.fetch('log')))
      end
      assert_equal "0 unknown\n1 park\n2 unknown\n3 wake_up\n4 unknown\nmax 7\n", File.binread(record.fetch('log'))
    end
    tree = @plan.files.fetch('include/erx/abi.h')
    assert_includes tree, "\tcase ERX_MF_DISPLAY_POLICY_SINGLE:\n\t\treturn (\"single\");"
    assert_includes tree, "\tcase ERX_MF_DISPLAY_POLICY_RIO:\n\t\treturn (\"rio\");"
    assert_includes tree, '#define ERX_MF_DISPLAY_POLICY_NAME_MAX 6'
  end

  # The tree's trace_event lookup gives each event's name and typed
  # arguments, and NULL for a value the enum does not hold, the largest
  # included; the header also builds freestanding.
  def test_trace_event_lookup_describes_each_event
    program = <<~C
      #include <stdio.h>
      #include <erx/abi.h>

      static void
      show(uint32_t value)
      {
      	static const char *const tags[] = { "none", "u64", "i64", "status" };
      	const erx_abi_event_t *event = erx_trace_event_describe(value);

      	if (event == NULL) {
      		printf("%u unknown\\n", value);
      		return;
      	}
      	printf("%u %s", value, event->name);
      	for (uint32_t i = 0; i < event->nargs; i++)
      		printf(" %s:%s", event->args[i].name, tags[event->args[i].type]);
      	printf("\\n");
      }

      int
      main(void)
      {
      	for (uint32_t value = 0; value <= 6; value++)
      		show(value);
      	show(UINT32_MAX);
      	return (0);
      }
    C
    Dir.mktmpdir('erx-abi-events-') do |directory|
      include_dir = File.join(directory, 'include/erx')
      FileUtils.mkdir_p(include_dir)
      File.write(File.join(include_dir, 'abi.h'), @plan.files.fetch('include/erx/abi.h'))
      File.write(File.join(directory, 'events.c'), program)
      File.write(File.join(directory, 'freestanding.c'), "#include <erx/abi.h>\n")
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'), timeout_program: 'gtimeout')
      flags = ['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I', File.join(directory, 'include')]
      begin
        runner.run(flags + ['-ffreestanding', '-fsyntax-only', File.join(directory, 'freestanding.c')],
                   name: 'freestanding', deadline: 60)
        runner.run(flags + ['-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-o', File.join(directory, 'events'),
                            File.join(directory, 'events.c')], name: 'build', deadline: 60)
        record = runner.run([File.join(directory, 'events')], name: 'events', deadline: 60)
      rescue Erx::CommandError => error
        flunk(File.binread(error.result.fetch('log')))
      end
      assert_equal <<~TEXT, File.binread(record.fetch('log'))
        0 unknown
        1 park slot:u64 deadline:u64
        2 wake slot:u64 result:status
        3 irq_deliver label:u64
        4 space_start target:u64
        5 space_end target:u64 status:i64
        6 unknown
        4294967295 unknown
      TEXT
    end
  end

end
