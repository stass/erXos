# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/abi_model'
require_relative '../../tools/lib/erx/abi_emit_c'
require_relative '../../tools/lib/erx/abi_emit_calls'
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
    model = schema("layout sample wire_le 8 16\n  field first u64 0\n  field second u32 8\n  padding 12 4\n")
    layout = model.types.fetch('sample')
    assert_equal 16, layout.size
    assert_equal [0, 8], layout.fields.map(&:offset)
  end

  # A record's version is the limit its writer stores and its reader checks;
  # a layout line has no second version to disagree with it.
  def test_layout_line_carries_no_version
    error = assert_raises(Erx::ABI::SchemaError) do
      schema("layout sample 1 wire_le 8 8\n  field first u64 0\n")
    end
    assert_match(/expected 4 fields for layout/, error.message)
  end

  def test_emitter_prefix_normalization_cannot_merge_constants
    assert_raises(Erx::ABI::SchemaError) do
      schema("limit foo u32 1\nlimit erx_foo u32 2\n")
    end
  end

  def test_constant_cannot_replace_a_generated_layout_alignment
    assert_raises(Erx::ABI::SchemaError) do
      schema("limit sample_align u32 16\nlayout sample wire_le 8 8\n  field value u64 0\n")
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
      schema("layout abi_fail wire_le 4 4\n  field value u32 0\n")
    end
  end

  def test_by_value_depth_is_bounded_before_emission
    body = "layout level0 wire_le 1 1\n  field byte u8 0\n"
    65.times do |index|
      body += "layout level#{index + 1} wire_le 1 1\n  field inner level#{index} 0\n"
    end
    error = assert_raises(Erx::ABI::SchemaError) { schema(body) }
    assert_match(/by-value type depth exceeds 64/, error.message)
  end

  def test_guard_requires_a_known_scalar_tag_in_the_same_record
    source = <<~ABI
      enum kind u32
        value selected 1
      layout packet wire_le 4 8
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
      schema("layout sample wire_le 8 8\n  field parent.child u64 0\n")
    end
  end

  def test_c_keyword_cannot_name_a_field
    assert_raises(Erx::ABI::SchemaError) do
      schema("layout sample wire_le 8 8\n  field return u64 0\n")
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

  # The UTCB layout, an aggregate and a capability type that the call rules
  # below are checked against.
  CALL_CONTEXT = <<~ABI
    limit msg_words u32 63
    scalar cap u64
    right stop 0 "stop a space"
    type space 1
      rights stop
      pass none
    layout erx_utcb shared 8 512
      field mr u64 0 count @msg_words
      field self u64 504
      atomic mr[] load acquire store release
      atomic self load acquire store none
      writer mr[] thread_context
      writer self kernel_boot
      owner mr[] caller all
      owner self kernel all
      visibility mr[] development
      visibility self internal
    layout pair wire_le 8 16
      field low u64 0
      field high u32 8
      padding 12 4
    layout tailed wire_le 8 8
      field count u32 0
      padding 4 4
      tail items u64 count 4
  ABI

  def call_model(members, waits: 'no', executor: 'allow', context: CALL_CONTEXT)
    lines = [context, 'call probe 1', "  waits #{waits}"]
    lines << "  executor #{executor}" if executor
    lines.concat(['  effects changes', '  charges none', '  bound records 1', members])
    schema(lines.join("\n") + "\n", architecture: architecture).calls.fetch('probe')
  end

  def assert_call_refused(members, pattern, **properties)
    error = assert_raises(Erx::ABI::SchemaError) { call_model(members, **properties) }
    assert_match(pattern, error.message)
  end

  def test_waiting_call_may_admit_executors_as_park_does
    call = call_model('  arg deadline u64 register 0', waits: 'yes', executor: 'allow')
    assert_equal({ rule: 'allow', argument: nil }, call.fetch(:executor))
  end

  def test_private_executor_rule_names_a_register_word
    call = call_model("  arg addr u64 register 0\n  arg expected u32 register 1",
                      waits: 'yes', executor: 'private addr')
    assert_equal({ rule: 'private', argument: 'addr' }, call.fetch(:executor))
    assert_call_refused('  arg addr u64 register 0', /private executor rule must name/,
                        waits: 'yes', executor: 'private missing')
    assert_call_refused('  arg space cap space stop register 0', /private executor rule must name/,
                        waits: 'yes', executor: 'private space')
    assert_call_refused('  arg addr u64 utcb mr[0]', /private executor rule must name/,
                        waits: 'yes', executor: 'private addr')
    assert_call_refused('  arg addr u64 register 0', /executor needs allow, refuse or private/,
                        waits: 'yes', executor: 'private')
    assert_call_refused('  arg flag u8 register 0', /private executor rule must name a u64/,
                        waits: 'yes', executor: 'private flag')
  end

  # The dispatch refuses an executor by class only before a wait; a call
  # that never waits leaves any refusal to its handler's own status.
  def test_call_that_does_not_wait_cannot_refuse_executors
    ['refuse', 'private addr'].each do |rule|
      assert_call_refused('  arg addr u64 register 0', /does not wait must allow executors/,
                          waits: 'no', executor: rule)
    end
  end

  def test_call_without_an_executor_rule_is_refused
    %w[yes no].each do |waits|
      assert_call_refused('  arg value u64 register 0', /needs waits, executor/, waits: waits, executor: nil)
    end
    assert_call_refused('  arg value u64 register 0', /executor needs allow, refuse or private/,
                        waits: 'yes', executor: 'sometimes')
  end

  def test_register_limits_count_register_words_not_parameters
    registers = (0..5).map { |index| "  arg r#{index} u64 register #{index}" }
    call = call_model((registers + ['  arg extra pair utcb mr[0]', '  result first u64 register 0',
                                    '  result second u64 register 1', '  result third pair utcb mr[2]']).join("\n"))
    assert_equal 7, call.fetch(:arguments).size
    assert_equal 3, call.fetch(:results).size
    assert_call_refused('  arg late u64 register 6', /outside 0..5/)
    assert_call_refused('  result late u64 register 2', /outside 0..1/)
    assert_call_refused("  arg one u64 register 0\n  arg two u32 register 0", /duplicate parameter register/)
    assert_call_refused('  arg wide pair register 0', /not one integer word/)
  end

  def test_utcb_aggregates_stay_inside_the_message_words
    call = call_model('  arg last pair utcb mr[61]')
    assert_equal [61, 2], call.fetch(:arguments).first.values_at(:slot, :words)
    assert_call_refused('  arg late pair utcb mr[62]', /beyond the message words/)
    assert_call_refused('  arg late u64 utcb mr[63]', /beyond the message words/)
    assert_call_refused('  arg late u64 utcb mr[99999]', /mr\[INDEX\]/)
  end

  def test_utcb_parameters_cannot_share_a_word
    call = call_model("  arg first pair utcb mr[0]\n  arg second pair utcb mr[2]\n  result back pair utcb mr[1]")
    assert_equal [0, 2], call.fetch(:arguments).map { |argument| argument.fetch(:slot) }
    assert_call_refused("  arg first pair utcb mr[0]\n  arg second u32 utcb mr[1]", /UTCB parameter words overlap/)
    assert_call_refused("  arg first u32 utcb mr[4]\n  arg second u32 utcb mr[4]", /UTCB parameter words overlap/)
    assert_call_refused("  result first pair utcb mr[3]\n  result second pair utcb mr[4]", /UTCB parameter words overlap/)
  end

  def test_utcb_location_names_a_message_word_of_the_declared_utcb
    assert_call_refused('  arg value u64 utcb 0', /mr\[INDEX\]/)
    assert_call_refused('  arg value u64 utcb self', /mr\[INDEX\]/)
    assert_call_refused('  arg value u64 utcb mr[01]', /mr\[INDEX\]/)
    without_utcb = CALL_CONTEXT.sub(/^layout erx_utcb.*?(?=^layout pair)/m, '')
    assert_call_refused('  arg value u64 utcb mr[0]', /needs layout erx_utcb/, context: without_utcb)
  end

  def test_utcb_aggregate_must_be_a_fixed_wire_layout
    assert_call_refused('  arg rows tailed utcb mr[0]', /fixed wire layout/)
    assert_call_refused('  arg words erx_utcb utcb mr[0]', /fixed wire layout/)
  end

  # The decoder checks a UTCB field as it checks a register argument, and
  # has no comparison for a fixed byte value, so the schema refuses one.
  def test_utcb_bytes_cannot_carry_a_fixed_value
    context = CALL_CONTEXT + "bytes magic 2 value 4552\n"
    assert_call_refused('  arg tag magic utcb mr[0]', /fixed value/, context: context)
  end

  def test_retry_needs_a_waiting_call_with_a_capability_to_look_up
    call = call_model("  retry\n  arg space cap space stop register 0", waits: 'yes', executor: 'refuse')
    assert call.fetch(:retry)
    assert_call_refused("  retry\n  arg space cap space stop register 0", /retry needs a waiting call/)
    assert_call_refused("  retry\n  arg value u64 register 0", /retry needs a waiting call/,
                        waits: 'yes', executor: 'refuse')
    assert_call_refused("  retry\n  retry\n  arg space cap space stop register 0", /duplicate retry/,
                        waits: 'yes', executor: 'refuse')
  end

  # The dispatch takes at most one existence lock; a result is
  # never looked up, so it cannot hold one.
  def test_a_call_holds_at_most_one_existence_lock
    one = "  arg s0 cap space stop register 0 exists\n  arg s1 cap space stop register 1"
    assert_equal [true, false], call_model(one).fetch(:arguments).map { |argument| argument.fetch(:exists) }
    two = (0..1).map { |slot| "  arg s#{slot} cap space stop register #{slot} exists" }.join("\n")
    assert_call_refused(two, /at most one existence lock/)
    assert_call_refused('  result made cap space stop register 0 exists', /result cannot hold an existence lock/)
  end

  # A window's capability states the right its direction needs, so a holder
  # of MAP alone cannot have the kernel read or write the object for it.
  def test_a_window_capability_needs_the_right_of_its_direction
    context = CALL_CONTEXT + <<~ABI
      limit copy_max u32 1048576
      right read 1 "read"
      right write 2 "write"
      right map 3 "map"
      type memory 2
        rights read,write,map
        pass none
    ABI
    window = lambda do |rights, direction|
      "  arg mem cap memory #{rights} register 0\n  arg off u64 register 1\n  arg len u32 register 2\n" \
        "  window w mem off len #{direction} @copy_max"
    end
    reading = call_model(window.call('read,map', 'read'), context: context)
    assert_equal 'read', reading.fetch(:windows).first.fetch(:direction)
    assert_call_refused(window.call('map', 'read'), /window.*needs the read right/, context: context)
    assert_call_refused(window.call('write', 'read'), /window.*needs the read right/, context: context)
    written ="#{context}call probe 1\n  waits no\n  executor allow\n  effects reads\n  charges none\n  bound records 1\n"
    refused = assert_raises(Erx::ABI::SchemaError) do
      schema(written + window.call('map', 'write') + "\n", architecture: architecture)
    end
    assert_match(/window.*needs the write right/, refused.message)
    locked = window.call('read,map', 'read').sub('register 0', 'register 0 exists')
    assert_call_refused(locked, /window capability cannot hold an existence lock/, context: context)
  end

  # Each argument's position constant is one name with one value.
  def test_position_constants_cannot_collide
    context = CALL_CONTEXT + <<~ABI
      status ok 0 "success"
      status inval -1 "invalid"
      status notsup -12 "unsupported"
      status wouldblock -14 "executor"
      right call 1 "call"
      call a_b 1
        waits no
        executor allow
        effects changes
        charges none
        bound records 1
        arg c cap space stop register 0
      call a 2
        waits no
        executor allow
        effects changes
        charges none
        bound records 1
        arg b_c cap space stop register 0
    ABI
    error = assert_raises(Erx::ABI::SchemaError) do
      Erx::ABI::CallEmitter.outputs(schema(context, architecture: architecture))
    end
    assert_match(/position constant ERX_SYS_POSITION_A_B_C/, error.message)
  end

  # A capability inside an aggregate has no declared type or rights, so no
  # lookup could check it; only a whole `cap` argument enters the plan.
  def test_an_aggregate_argument_cannot_carry_a_capability
    context = CALL_CONTEXT + "layout boxed wire_le 8 8\n  field held cap 0\n" \
                             "layout nested wire_le 8 8\n  field inner boxed 0\n"
    assert_call_refused('  arg box boxed utcb mr[0]', /aggregate argument cannot carry a capability/, context: context)
    assert_call_refused('  arg box nested utcb mr[0]', /aggregate argument cannot carry a capability/, context: context)
    returned = call_model('  result box boxed utcb mr[0]', context: context)
    assert_equal 'boxed', returned.fetch(:results).first.fetch(:type).name
  end

  # A root capability names its slot and the creation kind that fixes its
  # type and rights; it states no rights of its own.
  def test_root_capabilities_take_their_type_and_rights_from_a_kind
    context = <<~ABI
      right stop 0 "stop a space"
      type space 1
        rights stop
        pass none
      kind new_space 1 space
        default stop
      scalar cap u64
    ABI
    caps = schema(context + "cap new_space 1 new_space\ncap spare 2 new_space optional\n").caps
    assert_equal({ slot: 1, kind: 'new_space', type: 'space', optional: false }, caps.fetch('new_space'))
    assert caps.fetch('spare').fetch(:optional)
    extension = schema(context + "cap second 2 new_space\ncap first 1 new_space\n").types.fetch('erx_boot_root_extension')
    assert_equal [['first', 0], ['second', 8]], extension.fields.map { |field| [field.name, field.offset] }
    assert_equal 16, extension.size
    { 'cap self 7 space stop' => /unknown root capability presence stop/,
      'cap self 7 missing' => /undefined root capability kind/,
      'cap self 7 new_space maybe' => /unknown root capability presence/,
      'cap self 0 new_space' => /positive/,
      "cap self 7 new_space\ncap other 7 new_space" => /duplicate root slot/,
      "cap self 7 new_space\ncap self 8 new_space" => /duplicate root capability/,
      'cap self 7' => /needs a slot, a kind/,
      "cap self 1 new_space\ncap other 3 new_space" => /run from 1 without a gap/,
      'cap self 2 new_space' => /run from 1 without a gap/,
      "cap self 1 new_space\nlayout erx_boot_root_extension wire_le 8 8\n  field a u64 0" => /duplicate definition/ }.each do |line, pattern|
      error = assert_raises(Erx::ABI::SchemaError) { schema(context + line + "\n") }
      assert_match(pattern, error.message)
    end
  end

  # A pinned answer, not one the generator derives: the waiting calls an
  # executor may make are erx_park and erx_umtx_wait on private memory
  # (design-scheduler.md, Executor class enforcement). A new waiting call
  # left admissible to executors fails here until this list is changed.
  def test_shipped_waiting_calls_admit_executors_only_where_the_design_does
    root = File.expand_path('../..', __dir__)
    model = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    admitted = model.calls.select { |_name, call| call.fetch(:properties).fetch('waits') == 'yes' }
                    .reject { |_name, call| call.fetch(:executor).fetch(:rule) == 'refuse' }
                    .transform_values { |call| call.fetch(:executor).fetch(:rule) }
    allowed = { 'park' => 'allow', 'umtx_wait' => 'private' }
    admitted.each { |name, rule| assert_equal allowed[name], rule, "waiting call #{name} admits executors" }
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
    assert_equal 96, model.types.fetch('erx_pack_header').size
    assert_equal 64, model.types.fetch('erx_pack_entry').size
    assert_equal 32, model.types.fetch('erx_boot_locator').size
    assert_equal 376, model.types.fetch('erx_manifest').size
  end

  def test_nested_projection_cannot_hide_development_leaf
    body = <<~ABI
      layout inner wire_le 8 8
        field secret u64 0
        visibility secret development
      layout outer wire_le 8 8
        field inner inner 0
      projection public_view outer release
        show inner
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_public_projection_requires_explicit_leaf_visibility
    body = "layout sample wire_le 8 8\n  field value u64 0\nprojection public_view sample release\n  show value\n"
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_input_role_covers_nested_fields
    body = <<~ABI
      layout inner wire_le 4 4
        field tag u32 0
        owner tag caller all
        input_mask tag caller all
      layout outer wire_le 4 4
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
      layout inner native 8 8
        field value u64 0
      layout outer wire_le 8 8
        field inner inner 0
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  PRIVATE = "layout erx_secret native 8 16\n  private kernel/core/secret.c\n  field value u64 0\n  field other u64 8\n"

  # A private layout leaves the public header its tag, size and alignment;
  # its offsets, record and operations go to its own header alone.
  def test_a_private_layout_is_defined_only_in_its_own_header
    model = schema(PRIVATE)
    secret = model.types.fetch('erx_secret')
    assert_equal ['kernel/core/secret.c', 'kernel/generated/secret_impl.h'], [secret.private_owner, secret.private_header]
    assert secret.private?
    open = schema("layout open native 8 8\n  field value u64 0\n").types.fetch('open')
    assert_equal [false, nil], [open.private?, open.private_header]
    public_header = Erx::ABI::CEmitter.header(model)
    assert_includes public_header, "#define ERX_SECRET_SIZE 16\n#define ERX_SECRET_ALIGN 8\n" \
                                   "typedef struct erx_secret erx_secret_t;\n"
    refute_match(/struct erx_secret \{|ERX_SECRET_OFF_/, public_header)
    headers = Erx::ABI::CEmitter.private_headers(model)
    assert_equal ['kernel/generated/secret_impl.h'], headers.keys
    text = headers.fetch('kernel/generated/secret_impl.h')
    assert_includes text, "#ifndef ERX_SECRET_IMPL_H\n#define ERX_SECRET_IMPL_H\n\n#include \"erx/abi.h\"\n"
    assert_includes text, "#define ERX_SECRET_OFF_OTHER 8\nstruct erx_secret {\n"
    assert_includes text, '_Static_assert(sizeof(erx_secret_t) == ERX_SECRET_SIZE, "erx_secret size");'
    assert_empty Erx::ABI::CEmitter.private_headers(schema("layout open native 8 8\n  field value u64 0\n"))
  end

  # A private layout names one owner, a C source by a plain relative path.
  # Nothing public may hold a private layout, and a wire layout, which
  # another party decodes, cannot be one.
  def test_a_private_layout_stays_out_of_every_public_declaration
    refusals = {
      'wire storage' => "layout erx_secret wire_le 8 8\n  private kernel/core/secret.c\n  field value u64 0\n",
      'twice' => "layout erx_secret native 8 8\n  private kernel/core/secret.c\n  private kernel/core/secret.c\n" \
                 "  field value u64 0\n",
      'no owner' => "layout erx_secret native 8 8\n  private\n  field value u64 0\n",
      'two owners' => "layout erx_secret native 8 8\n  private kernel/core/a.c kernel/core/b.c\n  field value u64 0\n",
      'a header owner' => "layout erx_secret native 8 8\n  private kernel/core/secret.h\n  field value u64 0\n",
      'an absolute owner' => "layout erx_secret native 8 8\n  private /kernel/core/secret.c\n  field value u64 0\n",
      'an escaping owner' => "layout erx_secret native 8 8\n  private kernel/../secret.c\n  field value u64 0\n",
      'embedded' => "#{PRIVATE}layout outer native 8 16\n  field inner erx_secret 0\n",
      'a tail' => "#{PRIVATE}layout outer native 8 8\n  field count u32 0\n  padding 4 4\n" \
                  "  tail items erx_secret count 4\n",
      'projected' => "#{PRIVATE}projection view erx_secret release\n  show value\n  show other\n"
    }
    refusals.each do |name, body|
      assert_raises(Erx::ABI::SchemaError, name) { Erx::ABI::CEmitter.private_headers(schema(body)) }
    end
  end

  def test_reader_requires_wire_storage
    body = "layout sample native 8 8\n  field value u64 0\nreader check sample 8\n"
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_explicit_one_element_array_keeps_its_array_type
    body = <<~ABI
      layout sample shared 8 8
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
        pass none
      #{call_source('  arg target cap memory')}
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body, architecture: architecture) }
  end

  def test_signed_value_reference_is_not_treated_as_an_offset
    body = <<~ABI
      limit expected i32 -1
      layout sample wire_le 4 4
        field value i32 0
      reader check sample 4
        value root.value @expected
    ABI
    model = schema(body)
    assert_equal [-1], model.readers.first.rules.first.fetch(:values)
  end

  def test_abi_version_is_available_to_reader_constraints
    body = <<~ABI
      layout sample wire_le 4 4
        field version u32 0
      reader check sample 4
        value root.version @abi_version
    ABI
    assert_equal [1], schema(body).readers.first.rules.first.fetch(:values)
  end

  def test_reader_path_components_are_immutable
    body = "layout sample wire_le 4 4\n  field version u32 0\nreader check sample 4\n  value root.version 1\n"
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
      layout item wire_le 4 4
        field value u32 0
      layout packet wire_le 4 4
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
      layout item wire_le 4 4
        field flags options 0
      layout packet wire_le 4 8
        field items item 0 count 2
      reader packet_reader packet 8
    ABI
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  # A reader refuses an unknown bit by masking with the one generated constant, so a bit
  # added to the declaration is accepted everywhere at once.
  def test_flags_declare_the_mask_of_their_known_bits
    body = "flags options_flags u32\n  bit enabled 0\n  bit spare 3\n"
    known = schema(body).constants.fetch('options_flags_known')
    assert_equal 0b1001, known.value
    assert_equal 'u32', known.type.name
    assert_raises(Erx::ABI::SchemaError) { schema("#{body}enum options_kind u8\n  value flags_known 1\n") }
  end

  def test_debug_log_is_bounded_by_utcb_message_bytes
    root = File.expand_path('../..', __dir__)
    model = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    argument = model.calls.fetch('debug_log').fetch(:arguments).first
    assert_equal 504, argument.fetch(:type).maximum
    assert_equal 504, model.calls.fetch('debug_log').fetch(:bounds).fetch('bytes')
  end

  def test_tail_members_cannot_use_c_keywords
    body = "layout packet wire_le 4 4\n  field count u32 0\n  tail return u32 count 8\n"
    assert_raises(Erx::ABI::SchemaError) { schema(body) }
  end

  def test_reader_table_names_are_local_and_cannot_replace_root_scope
    ['qualified.table', 'root'].each do |name|
      body = <<~ABI
        layout item wire_le 4 4
          field value u32 0
        layout packet wire_le 4 8
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
    model = schema("layout packet wire_le 4 4\n  field value u32 0\nreader example.reader packet 4\n")
    compile_reader(model)
  end

  def test_tableless_reader_rejects_unknown_order_entries
    body = "layout packet wire_le 4 4\n  field value u32 0\nreader check packet 4\n"
    assert_empty schema(body).readers.first.order
    error = assert_raises(Erx::ABI::SchemaError) { schema(body + "  order absent\n") }
    assert_includes error.message, 'table order must name every table exactly once'
  end

  def test_string_table_only_reader_compiles
    model = schema(<<~ABI)
      layout packet wire_le 4 8
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
  # An enum's args lines type the arg words of the record a layout's
  # names line binds it to; each form below is refused with its own
  # message, so a generator that accepts one fails here.
  def event_schema(args: "  args park slot:u64 deadline:u64\n  args wake result:status\n",
                   enum: "enum trace_event u32\n  value park 1\n  value wake 2\n",
                   names: "  names event trace_event args arg\n  names flags trace_record_flags\n")
    schema(<<~ABI + enum + args + <<~LAYOUT + names)
      flags trace_record_flags u16
        bit cpu_unknown 0
    ABI
      layout erx_trace_record wire_le 8 48
        field seq u64 0
        field event u32 8
        field flags u16 12
        padding 14 2
        field status u64 16
        field arg u64 24 count 3
    LAYOUT
  end

  def assert_event_refused(pattern, **source)
    error = assert_raises(Erx::ABI::SchemaError) { event_schema(**source) }
    assert_match pattern, error.message
  end

  def test_event_arguments_are_typed_in_order
    model = event_schema
    events = model.types.fetch('trace_event').args
    assert_equal [%w[slot u64], %w[deadline u64]], events.fetch('park').map { |item| [item.name, item.type] }
    assert_equal [%w[result status]], events.fetch('wake').map { |item| [item.name, item.type] }
    bindings = model.types.fetch('erx_trace_record').bindings
    assert_equal({ 'event' => %w[trace_event arg], 'flags' => ['trace_record_flags', nil] },
                 bindings.transform_values { |binding| [binding.type, binding.args] })
    assert_predicate model.types.fetch('trace_event').args, :frozen?
  end

  def test_args_naming_no_member_is_refused
    assert_event_refused(/args names no member of trace_event: sleep/, args: "  args sleep slot:u64\n")
  end

  def test_second_args_line_for_a_member_is_refused
    assert_event_refused(/duplicate args line for member park/,
                         args: "  args park slot:u64\n  args park deadline:u64\n")
  end

  def test_more_than_three_arguments_are_refused
    assert_event_refused(/an event has at most 3 arguments/, args: "  args park a:u64 b:u64 c:u64 d:u64\n")
  end

  def test_argument_named_like_a_record_field_is_refused
    assert_event_refused(/event argument status is named like a field of the layout/,
                         args: "  args park status:i64\n")
    assert_event_refused(/event argument arg is named like a field of the layout/,
                         args: "  args wake arg:u64\n")
  end

  def test_unknown_argument_type_is_refused
    assert_event_refused(/unknown event argument type u32/, args: "  args park slot:u32\n")
  end

  def test_malformed_argument_is_refused
    assert_event_refused(/args requires NAME:TYPE, not slot/, args: "  args park slot\n")
    assert_event_refused(/args requires NAME:TYPE, not slot:u64:u64/, args: "  args park slot:u64:u64\n")
  end

  def test_repeated_argument_name_is_refused
    assert_event_refused(/duplicate event argument slot/, args: "  args park slot:u64 slot:i64\n")
  end

  def test_args_line_without_arguments_is_refused
    assert_event_refused(/args requires a member and at least one NAME:TYPE/, args: "  args park\n")
  end

  def test_args_on_flags_are_refused
    error = assert_raises(Erx::ABI::SchemaError) do
      schema("flags trace_record_flags u16\n  bit cpu_unknown 0\n  args cpu_unknown slot:u64\n")
    end
    assert_match(/args belong to an enum, not to flags/, error.message)
  end

  def test_args_on_a_sparse_or_negative_enum_are_refused
    assert_event_refused(/an enum with args has an unsigned base and members from 0 to 1023/,
                         enum: "enum trace_event u32\n  value park 1\n  value wake 1024\n")
    assert_event_refused(/an enum with args has an unsigned base and members from 0 to 1023/,
                         enum: "enum trace_event i32\n  value park -1\n  value wake 2\n")
  end

  def test_names_binds_the_arg_words_of_an_enum_with_args
    assert_event_refused(/trace_event has args lines, so names requires args ARRAY/,
                         names: "  names event trace_event\n")
    assert_event_refused(/trace_record_flags has no args lines to place in arg/,
                         names: "  names event trace_event args arg\n  names flags trace_record_flags args arg\n")
    assert_event_refused(/args status is not an array of at least 2 u64 words/,
                         names: "  names event trace_event args status\n")
    assert_event_refused(/args seq is not an array of at least 2 u64 words/,
                         names: "  names event trace_event args seq\n")
    assert_event_refused(/names requires FIELD TYPE \[args ARRAY\]/, names: "  names event trace_event words arg\n")
  end

  def test_args_line_is_a_member_line
    assert_event_refused(/args is a member line of its enum/,
                         enum: "enum trace_event u32\n  value park 1\n    args park slot:u64\n  value wake 2\n", args: '')
  end

  def test_args_accept_members_numbered_from_zero_to_the_bound
    model = event_schema(enum: "enum trace_event u32\n  value park 0\n  value wake 1023\n")
    assert_equal [0, 1023], model.types.fetch('trace_event').members.values.sort
  end

  def test_args_on_a_signed_enum_are_refused
    assert_event_refused(/an enum with args has an unsigned base/,
                         enum: "enum trace_event i32\n  value park 1\n  value wake 2\n")
  end

  def test_enum_with_args_that_no_layout_names_is_refused
    assert_event_refused(/enum trace_event has args but no layout names it/,
                         names: "  names flags trace_record_flags\n")
  end

  def test_names_line_is_checked_against_its_field
    assert_event_refused(/names requires a field of the layout: kind/, names: "  names kind trace_event args arg\n")
    assert_event_refused(/field flags is not one u32, the base of trace_event/, names: "  names flags trace_event args arg\n")
    assert_event_refused(/field arg is not one u32, the base of trace_event/, names: "  names arg trace_event args arg\n")
    assert_event_refused(/duplicate names line for field event/,
                         names: "  names event trace_event args arg\n  names event trace_event args arg\n")
    assert_event_refused(/names requires an enum or flags type: u32/, names: "  names event u32\n")
  end

end
