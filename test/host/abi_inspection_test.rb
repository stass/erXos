# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The reader of the inspection schema (docs/design-abi.md, "Inspection schema"):
# one seeded bad schema for each rule of the grammar, the shape of a resolved
# schema, and the generated outputs of the checked-in schema.
# test/host/erx_schema_test.rb runs the generated Erlang.
class AbiInspectionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ROOT_SOURCE = <<~ABI
    abi 1
    limit width u32 40
    status ok 0 "success"
    status inval -1 "invalid argument"
    right read 0 "read"
    right write 1 "write"
    type budget 1
      rights read,write
      pass read
    scalar page u64 range 0 1048576 align 4096
    enum colour u32
      value red 1
      value blue 2
    flags mode u32
      bit fast 0
      bit safe 1
  ABI
  BASE = <<~INSPECTION
    inspection 1
      integer index 0 9
      kind thing
        attr size index reporters kernel visible any build all projections shell
      path listing
      path listing things
      path thing things *index
  INSPECTION

  # A report of kind thing: its one kernel attribute size, and the mask.
  REPORT = <<~ABI
    enum info_kind u32
      value basic 0
      value thing 1
    flags info_thing_reported u32
      bit size 0
    layout erx_info_thing wire_le 4 8
      field size u32 0
      field reported info_thing_reported 4
  ABI

  # ROOT, root declarations added to ROOT_SOURCE, such as a report layout.
  def model(text, path: 'abi/inspection.txt', root: '')
    declarations = Erx::ABI::Syntax.parse(ROOT_SOURCE + root, path: 'abi/erx_abi.txt') +
                   Erx::ABI::Syntax.parse(text, path: path)
    Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: declarations.freeze, inputs: {}.freeze))
  end

  def assert_refused(text, pattern, path: 'abi/inspection.txt', root: '')
    error = assert_raises(Erx::ABI::SchemaError) { model(text, path: path, root: root) }
    assert_match(pattern, error.message)
  end

  # BASE with LINES added as members of the schema.
  def with(lines)
    BASE + lines.lines.map { |line| "  #{line}" }.join
  end

  # BASE with an attribute line added to its kind.
  def with_attr(line)
    BASE.sub("    attr size", "    attr #{line}\n    attr size")
  end

  def test_base_schema_resolves_its_paths
    inspection = model(BASE).inspection
    assert_equal 1, inspection.version
    assert_equal %w[listing listing thing], inspection.paths.map(&:kind)
    root, things, thing = inspection.paths
    assert_equal ['things'], root.literal_children
    assert_equal 'index', things.variable_child
    assert_equal [], thing.literal_children
    assert_nil thing.variable_child
    assert inspection.frozen? && inspection.paths.frozen? && thing.segments.last.frozen?
  end

  def test_a_root_without_an_inspection_schema_has_none
    assert_nil Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(
      declarations: Erx::ABI::Syntax.parse(ROOT_SOURCE, path: 'abi/erx_abi.txt'), inputs: {}
    )).inspection
  end

  def test_the_declaration_itself
    assert_refused(BASE, /belongs in abi\/inspection.txt/, path: 'abi/erx_abi.txt')
    assert_refused(BASE + BASE, /exactly one inspection declaration/)
    assert_refused(BASE.sub('inspection 1', 'inspection 0'), /must be positive/)
    assert_refused(BASE.sub('inspection 1', 'inspection 1 2'), /expected inspection SCHEMA/)
    assert_refused(with('frobnicate thing'), /unknown inspection member frobnicate/)
    assert_refused(BASE.sub("  integer index 0 9\n", "  integer index 0 9\n    utf8\n"),
                   /integer takes no four-space members/)
  end

  def test_names_are_declared_once_and_never_reserved
    assert_refused(with('integer index 0 3'), /duplicate inspection member index/)
    assert_refused(with('atoms thing a b'), /duplicate inspection member thing/)
    %w[kernel service runtime boolean pid rights object_type status listing none].each do |name|
      assert_refused(with("atoms #{name} a"), /#{name} is reserved/)
    end
    assert_refused(with('atoms Upper a'), /invalid inspection name/)
    assert_refused(with('atoms with.dot a'), /invalid inspection name/)
  end

  def test_quoting_is_exactly_for_labels_and_scopes
    assert_refused(with("unit pages pages\ninteger pc 0 1 unit pages"), /expected a quoted string/)
    assert_refused(with("atoms \"quoted\" a"), /quoted token is not permitted/)
    assert_refused(with("stopgap gap kernel \"label\" scope"), /expected a quoted string/)
    assert_refused(with("unit pages \"bad\\x01\"\ninteger pc 0 1 unit pages"), /printable ASCII/)
    assert_refused(with("unit pages \"\"\ninteger pc 0 1 unit pages"), /printable ASCII/)
  end

  def test_units_and_types_must_be_used
    assert_refused(with('unit pages "pages"'), /unit pages is not used/)
    assert_refused(with('integer spare 0 1'), /type spare is not used/)
    assert_refused(BASE.sub("  kind thing\n", "  kind spare\n  kind thing\n"), /kind spare has no path/)
    assert_refused(with('stopgap gap kernel "gap" "scope"'), /stopgap gap reports no attribute or trace row/)
  end

  def test_integer_bounds
    assert_refused(with_attr('n bad reporters kernel visible any build all projections shell') +
                   "  integer bad 9 0\n", /minimum exceeds its maximum/)
    assert_refused(with_attr('n bad reporters kernel visible any build all projections shell') +
                   "  integer bad 0 @colour\n", /@colour is not a root limit/)
    assert_refused(with_attr('n bad reporters kernel visible any build all projections shell') +
                   "  integer bad 0 0x10000000000000000\n", /outside the 64-bit range/)
    assert_refused(with_attr('n bad reporters kernel visible any build all projections shell') +
                   "  integer bad 0 9 unit missing\n", /undefined unit missing/)
    assert_refused(with_attr('n bad reporters kernel visible any build all projections shell') +
                   "  integer bad 0 9 units pages\n", /expected unit UNIT/)
    model(with_attr('n bad reporters kernel visible any build all projections shell') +
          "  integer bad -3 @width\n")
  end

  def test_text_list_tuple_and_atoms_bounds
    attr = with_attr('n bad reporters kernel visible any build all projections shell')
    assert_refused(attr + "  text bad 0\n", /bound must be 1 to 65536/)
    assert_refused(attr + "  text bad 65537\n", /bound must be 1 to 65536/)
    assert_refused(attr + "  text bad 8 ascii\n", /expected text NAME MAX \[utf8\]/)
    assert_refused(attr + "  list bad index 1001\n", /bound must be 1 to 1000/)
    assert_refused(attr + "  tuple bad index\n", /a tuple holds 2 to 16 values/)
    assert_refused(attr + "  tuple bad #{(['index'] * 17).join(' ')}\n", /a tuple holds 2 to 16 values/)
    assert_refused(attr + "  atoms bad a a\n", /duplicate atom/)
    assert_refused(attr + "  atoms bad\n", /expected atoms NAME ATOM/)
    model(attr + "  tuple bad #{(['index'] * 16).join(' ')}\n")
  end

  # No form takes an arbitrary term or an atom from the input, and a name
  # that is not a declared type, a built-in or a root type is not a type.
  def test_no_type_admits_an_arbitrary_term_or_an_input_atom
    %w[term any atom binary @width @budget].each do |name|
      assert_refused(with_attr("n #{name} reporters kernel visible any build all projections shell"),
                     /undefined inspection type|is not a root scalar, enum or flags|not a root/)
    end
  end

  def test_types_nest_at_most_eight_deep_and_never_cyclically
    chain = (1..8).map { |level| "list l#{level} #{level == 1 ? 'index' : "l#{level - 1}"} 2\n" }.join
    model(with_attr('n l7 reporters kernel visible any build all projections shell') + chain.lines.first(7).map { |line| "  #{line}" }.join)
    assert_refused(with_attr('n l8 reporters kernel visible any build all projections shell') +
                   chain.lines.map { |line| "  #{line}" }.join, /nested more than 8 deep/)
    assert_refused(with_attr('n a reporters kernel visible any build all projections shell') +
                   "  list a b 2\n  list b a 2\n", /refers to itself/)
  end

  def test_attributes_take_every_property_in_order
    assert_refused(with_attr('n index reporters kernel visible any build all'), /expected attr KEY TYPE/)
    assert_refused(with_attr('n index visible any reporters kernel build all projections shell'), /expected attr KEY TYPE/)
    assert_refused(with_attr('size index reporters kernel visible any build all projections shell'), /duplicate attribute size/)
    assert_refused(with_attr('n index reporters nobody visible any build all projections shell'), /undefined reporter nobody/)
    assert_refused(with_attr('n index reporters kernel,kernel visible any build all projections shell'), /duplicate or empty/)
    assert_refused(with_attr('n index reporters kernel visible some build all projections shell'), /unknown visibility some/)
    assert_refused(with_attr('n index reporters kernel visible any build release projections shell'), /unknown build release/)
    assert_refused(with_attr('n index reporters kernel visible any build all projections tty'), /unknown projection tty/)
    assert_refused(with_attr('n index reporters kernel visible any build all projections shell,shell'), /duplicate or empty/)
    model(with_attr('n index reporters kernel,service,runtime visible system_shell build development projections none'))
  end

  def test_a_stopgap_is_listed_with_its_category_and_has_its_own_label
    gap = 'stopgap gap kernel "gap" "what it sees"'
    assert_refused(with_attr('n index reporters service,gap visible any build all projections shell') + "  #{gap}\n",
                   /stopgap gap is listed without its category kernel/)
    assert_refused(with_attr('n index reporters kernel,gap visible any build all projections shell') +
                   "  stopgap gap device \"gap\" \"scope\"\n", /stands in for kernel, service or runtime/)
    assert_refused(with_attr('n index reporters kernel,gap visible any build all projections shell') +
                   "  stopgap gap kernel \"kernel\" \"scope\"\n", /is a category's name/)
    assert_refused(with_attr('n index reporters kernel,gap,other visible any build all projections shell') +
                   "  #{gap}\n  stopgap other kernel \"gap\" \"scope\"\n", /is another stopgap's/)
    stopgap = model(with_attr('n index reporters kernel,gap visible any build all projections shell') + "  #{gap}\n")
              .inspection.stopgaps.fetch('gap')
    assert_equal ['kernel', 'gap', 'what it sees'], [stopgap.category, stopgap.label, stopgap.scope]
  end

  # A trace row names one reporter; a stopgap a row lists is used, and the
  # kernel's row shares the category's name without declaring a member.
  def test_trace_rows_name_one_declared_reporter
    gap = 'stopgap gap kernel "gap" "what it sees"'
    rows = model(with("#{gap}\ntrace kernel kernel\ntrace backend gap")).inspection.trace_rows
    assert_equal({ 'kernel' => 'kernel', 'backend' => 'gap' }, rows.transform_values(&:reporter))
    assert_refused(with('trace backend gap'), /undefined reporter gap/)
    assert_refused(with('trace backend device'), /undefined reporter device/)
    assert_refused(with("trace erts runtime\ntrace erts runtime"), /duplicate trace row erts/)
    assert_refused(with('trace erts'), /expected trace ROW REPORTER/)
    assert_refused(with('trace erts runtime kernel'), /expected trace ROW REPORTER/)
    assert_refused(with('trace erts "runtime"'), /quoted token is not permitted/)
    assert_refused(with('trace Erts runtime'), /invalid inspection name/)
    assert_refused(with("trace erts runtime\n  extra"), /trace takes no four-space members/)
    assert_refused(with("#{gap}\ntrace erts runtime"), /stopgap gap reports no attribute or trace row/)
  end

  def test_paths_have_declared_prefixes_and_resolve_uniquely
    assert_refused(with('path thing other *index'), /proper prefix of this path is not declared/)
    assert_refused(with('path thing things *index'), /declared twice/)
    assert_refused(with('path listing things extra'), /literal segments or by one variable segment/)
    assert_refused(with("integer other 0 3\npath thing things *other"), /declared twice/)
    assert_refused(with("integer other 0 3\npath thing things *other more"),
                   /differs in type from its prefix/)
    assert_refused(with('path nothing things'), /undefined kind "nothing"/)
    assert_refused(with("atoms shade a b\npath listing shades\npath listing shades *shade"),
                   /an integer, a text of at most 256 bytes or a pid/)
    assert_refused(with("text long 257\npath listing names\npath listing names *long"),
                   /an integer, a text of at most 256 bytes or a pid/)
    deep = (1..17).map { |count| "path listing #{(['a'] * count).join(' ')}" }.join("\n")
    assert_refused(with(deep), /at most 16 segments/)
    model(with("text short 256\npath listing names\npath listing names *short\npath listing pids\npath listing pids *pid"))
  end

  def test_path_marks
    log = "path listing log\n  entries index 100\n  append_only\n"
    assert model(with(log)).inspection.paths.last.append_only
    assert_equal ['index', 100], model(with(log)).inspection.paths.last.entries
    assert_refused(with("path listing log\n  append_only"), /append_only marks a path with entries/)
    assert_refused(with("path listing log\n  entries index 0"), /bound must be 1/)
    assert_refused(with("path listing log\n  entries nothing 4"), /undefined inspection type nothing/)
    assert_refused(with("path listing log\n  visible all\n  visible any"), /duplicate path mark visible/)
    assert_refused(with("path listing log\n  visible everyone"), /unknown visibility everyone/)
    assert_refused(with("path listing log\n  hidden"), /unknown path mark hidden/)
  end

  # Presentation names are a namespace of their own, so a kind's name may be one.
  def test_present_marks
    marked = ->(name) { BASE.sub("things *index\n", "things *index\n    present #{name}\n") }
    assert_equal 'thing', model(marked.call('thing')).inspection.paths.last.present
    assert_refused(marked.call('accept'), /accept is not a presentation name/)
    assert_refused(marked.call('ws'), /ws is not a presentation name/)
    assert_refused(marked.call('kernel'), /kernel is not a presentation name/)
    assert_refused(marked.call('a' * 33), /invalid presentation name/)
    assert_refused(BASE.sub("things\n", "things\n    present things\n"), /a presented path has a variable segment/)
    others = "  path listing others\n  path thing others *index\n    present %s\n"
    assert_refused(marked.call('thing') + format(others, 'thing'), /presentation thing is declared twice/)
    assert_refused(marked.call('thing') + format(others, 'other'), /presentations thing and other both show type index/)
    model(marked.call('thing') + "  path listing others\n  path listing others *index\n" \
                                 "  path thing others *index *index\n    present pair\n")
    wide = "text wide 256\npath listing w\n" + (1..5).map { |depth| "path listing w#{' *wide' * depth}\n" }.join +
           "path thing w#{' *wide' * 6}\n  present wide"
    assert_refused(with(wide), /a presentation's text is at most 4096 bytes/)
    long = "text wide 256\npath listing w\n" + (1..3).map { |depth| "path listing w#{' *wide' * depth}\n" }.join +
           "path thing w#{' *wide' * 4}\n  present wide"
    assert_refused(with(long), /a presentation's link is at most 4096 bytes/)
  end

  # A path's visibility is its own mark and every mark above it.
  def test_visibility_reaches_every_path_below_its_mark
    text = BASE.sub("  path listing things\n", "  path listing things\n    visible all\n") +
           "  path listing things *index secret\n    visible system_shell\n"
    visibility = model(text).inspection.paths.to_h { |path| [path.segments.size, path.visibility] }
    assert_equal({ 0 => [], 1 => ['all'], 2 => ['all'], 3 => %w[all system_shell] }, visibility)
  end

  def test_a_derived_attribute_names_its_inputs
    total = 'total index reporters kernel visible any build all projections shell'
    attrs = model(with_attr("#{total} derived size")).inspection.kinds.fetch('thing')
    assert_equal [%w[size], []], attrs.map(&:derived)
    assert_refused(with_attr("#{total} derived nothing"), /derived input nothing is no attribute of the kind/)
    assert_refused(with_attr("#{total} derived total"), /derived input total is itself derived/)
    # Two attributes derived from each other: the first in field order is refused.
    cycle = with_attr("#{total} derived size").sub("projections shell\n  path listing\n",
                                                   "projections shell derived total\n  path listing\n")
    assert_refused(cycle, /derived input size is itself derived/)
    assert_refused(with_attr("#{total} derived size,size"), /duplicate or empty/)
    assert_refused(with_attr("#{total} derived"), /expected attr KEY TYPE .* \[derived INPUTS\]/)
    assert_refused(with_attr("#{total} from size"), /expected attr KEY TYPE/)
    assert_refused(with_attr("#{total} derived size extra"), /expected attr KEY TYPE/)
  end

  def test_an_attribute_lists_one_stopgap_for_each_category
    gaps = "  stopgap gap kernel \"gap\" \"scope\"\n  stopgap other kernel \"other\" \"scope\"\n" \
           "  stopgap svc service \"svc\" \"scope\"\n"
    assert_refused(with_attr('n index reporters kernel,gap,other visible any build all projections shell') + gaps,
                   /stopgaps gap and other both stand in for kernel/)
    two = with_attr("n index reporters kernel,gap,service,svc visible any build all projections shell\n    " \
                    'attr m index reporters kernel,other visible any build all projections shell')
    model(two + gaps)
  end

  def test_a_report_layout_is_named_after_its_kinds_kernel_attributes
    model(BASE, root: REPORT)
    model(BASE, root: REPORT.sub("  field size u32 0\n", "  field size u32 0\n  field id u32 8\n")
                            .sub('wire_le 4 8', 'wire_le 4 12'))
    model(with_attr('spare index reporters kernel visible any build all projections shell'), root: REPORT)
    renamed = REPORT.gsub(/\bsize\b/, 'weight')
    assert_refused(BASE, /erx_info_thing field weight names no attribute of its kind that lists kernel/, root: renamed)
    assert_refused(BASE.sub('size index reporters kernel', 'size index reporters service'),
                   /erx_info_thing field size names no attribute of its kind that lists kernel/, root: REPORT)
    with_total = REPORT.sub("  bit size 0\n", "  bit size 0\n  bit total 1\n")
                       .sub('field reported info_thing_reported 4', "field total u32 4\n  field reported info_thing_reported 8")
                       .sub('wire_le 4 8', 'wire_le 4 12')
    assert_refused(with_attr('total index reporters kernel visible any build all projections shell derived size'),
                   /erx_info_thing field total is a derived attribute/, root: with_total)
  end

  def test_a_report_layouts_reported_bits_are_exactly_its_attribute_fields
    assert_refused(BASE, /reported bit spare of erx_info_thing names no attribute field/,
                   root: REPORT.sub("  bit size 0\n", "  bit size 0\n  bit spare 1\n"))
    assert_refused(BASE, /reported bit id of erx_info_thing names no attribute field/,
                   root: REPORT.sub("  bit size 0\n", "  bit size 0\n  bit id 1\n")
                               .sub("  field size u32 0\n", "  field size u32 0\n  field id u32 8\n")
                               .sub('wire_le 4 8', 'wire_le 4 12'))
    assert_refused(with_attr('spare index reporters kernel visible any build all projections shell'),
                   /erx_info_thing field spare has no reported bit/,
                   root: REPORT.sub("  field size u32 0\n", "  field size u32 0\n  field spare u32 8\n")
                               .sub('wire_le 4 8', 'wire_le 4 12'))
    assert_refused(BASE, /erx_info_thing has no reported field/,
                   root: REPORT.sub('field reported info_thing_reported 4', 'padding 4 4'))
    assert_refused(BASE, /reported of erx_info_thing is not a flags field/,
                   root: REPORT.sub('field reported info_thing_reported 4', 'field reported u32 4'))
  end

  def test_a_topic_named_after_a_kind_needs_its_report_layout
    topics = "enum info_kind u32\n  value basic 0\n  value thing 1\n"
    assert_refused(BASE, /topic thing has no report layout erx_info_thing/, root: topics)
    model(BASE, root: REPORT)
    assert_refused(BASE, /report layouts erx_info_thing need the topic enum info_kind/,
                   root: REPORT.sub("enum info_kind u32\n  value basic 0\n  value thing 1\n", ''))
    model(BASE, root: "enum info_kind u32\n  value basic 0\n")
  end

  # The build's own generator refuses the checked-in ABI with one seeded
  # mismatch: the budget layout's threshold field spelt watch.
  def test_the_checked_in_abi_fails_with_a_seeded_mismatch
    Dir.mktmpdir('erx-inspection-seed-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/erx_abi.txt')
      text = File.read(path)
      seeded = text.sub("  field threshold u64 48\n", "  field watch u64 48\n")
      refute_equal text, seeded
      File.write(path, seeded)
      error = assert_raises(Erx::ABI::SchemaError) do
        Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64'))
      end
      assert_match(/erx_info_budget field watch names no attribute of its kind that lists kernel/, error.message)
    end
  end

  def test_the_checked_in_schema_declares_the_budget_stopgap
    inspection = Erx::ABI::Generator.plan(root: ROOT).schema.inspection
    used = inspection.kinds.fetch('budget').find { |attr| attr.key == 'used' }
    assert_equal %w[kernel liberx_pool], used.reporters
    stopgap = inspection.stopgaps.fetch('liberx_pool')
    assert_equal %w[kernel root\ pool], [stopgap.category, stopgap.label]
    assert_equal %w[machine cpu group budget domain thread process log module], inspection.kinds.keys
    derived = inspection.kinds.fetch('budget').reject { |attr| attr.derived.empty? }.map(&:key)
    assert_equal %w[spending borrowing room deficit give_back], derived
    assert_equal({ 'erts' => 'runtime', 'backend' => 'liberx_trace', 'kernel' => 'kernel' },
                 inspection.trace_rows.transform_values(&:reporter))
    assert_equal %w[kernel liberx\ trace], inspection.stopgaps.fetch('liberx_trace').then { |gap| [gap.category, gap.label] }
  end

  # The generated table in the build tree.
  def test_the_host_table_matches_the_schema
    require_relative '../../tools/lib/erx/generated_abi_inspection'
    generated = Erx::ABI::Generated::Inspection
    inspection = Erx::ABI::Generator.plan(root: ROOT).schema.inspection
    assert_equal inspection.version, generated::SCHEMA
    assert_equal inspection.kinds.transform_values { |attrs| attrs.map(&:key) }.merge('listing' => []),
                 generated::KINDS.transform_values { |attrs| attrs.map { |attr| attr.fetch(:key) } }
    assert_equal 'root pool', generated::STOPGAPS.fetch('liberx_pool').fetch(:label)
    assert_equal inspection.trace_rows.transform_values(&:reporter), generated::TRACE_ROWS
    process = generated::PATHS.find { |path| path.fetch(:segments).first == 'processes' && path.fetch(:segments).size == 2 }
    assert_equal ['processes', { type: 'pid' }], process.fetch(:segments)
    assert generated::PATHS.frozen? && process.fetch(:segments).last.frozen?
    assert_equal %w[kernel log], generated::PATHS.last.fetch(:segments)
  end

  def test_a_root_without_inspection_cannot_plan_outputs
    Dir.mktmpdir('erx-inspection-missing-') do |root|
      FileUtils.mkdir_p(File.join(root, 'abi'))
      File.write(File.join(root, 'abi/erx_abi.txt'), "abi 1\n")
      error = assert_raises(Erx::ABI::SchemaError) { Erx::ABI::Generator.plan(root: root, architecture: nil) }
      assert_match(/includes no inspection schema/, error.message)
    end
  end
end
