# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsCapTest < Minitest::Test
  include ChokepointsHelper

  # A slot's record reaches only the capability core, its host drivers and
  # its fuzzer, through the generated private header; every other file
  # sees the incomplete type of include/erx/abi.h and only refers to it. A
  # member write outside the core therefore needs the header, which is
  # refused, or a definition of the record, which is refused too.
  def test_cap_slot_records_are_private_to_the_capability_core
    slots = [rule('cap-slot-private')]
    # The rule is built from the ABI file's declaration of the slot's
    # owner, one rule per private layout, and the owner exists.
    owners = Rules::PRIVATE_LAYOUTS.to_h { |layout| [layout.name, layout.private_owner] }
    assert_equal Rules::CAP_CORE, owners.fetch('erx_cap_slot')
    assert_includes slots.first.rule, "only #{Rules::CAP_CORE}, which the ABI file names as the owner"
    owners.each_value { |owner| assert File.file?(File.join(ROOT, owner)), owner }
    include_impl = "#include \"cap_slot_impl.h\"\n"
    allowed = {
      Rules::CAP_CORE => "#include \"erx/cap.h\"\n#{include_impl}",
      'test/fixtures/cap_newer_driver.c' => include_impl,
      'test/fixtures/cap_driver.c' => include_impl,
      'test/fixtures/cap_churn.c' => "#include <cap_slot_impl.h>\n",
      'tools/fuzz/cap_fuzz.c' => include_impl,
      Rules::CAP_SLOT_IMPL => "#include <erx/abi.h>\nstruct erx_cap_slot {\n\t_Atomic uint64_t object;\n};\n" \
                              "_Static_assert(sizeof(struct erx_cap_slot) == ERX_CAP_SLOT_SIZE, \"size\");\n",
      'include/erx/abi.h' => "typedef struct erx_cap_slot erx_cap_slot_t;\n",
      'include/erx/cap.h' => "erx_status_t erx_cap_grow(erx_cap_table_t *, erx_cap_slot_t *);\n",
      'kernel/core/space.c' => "void f(struct erx_cap_slot *page);\nsize_t g(void) { return ERX_CAP_SLOT_SIZE; }\n"
    }
    assert_empty evaluate(slots, allowed)
    member_write = "#include \"erx/cap.h\"\n#{include_impl}void f(erx_cap_slot_t *s) { s->rights = 0; }\n"
    found = evaluate(slots, { 'kernel/core/space.c' => member_write })
    assert_equal ['cap-slot-private: kernel/core/space.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    # Another core is no exception, nor is the budget core's driver.
    refute_empty evaluate(slots, { 'kernel/core/budget.c' => include_impl })
    refute_empty evaluate(slots, { Rules::BUDGET_DRIVER => include_impl })
    # A file that defines the record itself is refused wherever it is.
    refute_empty evaluate(slots, { 'kernel/core/space.c' => "struct erx_cap_slot {\n\tuint32_t rights;\n};\n" })
    refute_empty evaluate(slots, { Rules::CAP_CORE => "struct erx_cap_slot { uint32_t rights; };\n" })
  end

  # A table's record reaches only the capability core and its host tests,
  # through kernel/core/cap_impl.h; every other file sees the incomplete
  # type cap.h declares. A write of a table's member outside the core
  # therefore needs that header or a definition of the record, and the
  # rules refuse both, in another core as anywhere else.
  def test_cap_table_records_are_private_to_the_capability_core
    member_write = "#include \"erx/cap.h\"\n#include \"cap_impl.h\"\n" \
                   "void f(erx_cap_table_t *t, void *forged) { t->pages[0] = forged; t->capacity = 0; }\n"
    found = evaluate(Rules::ACTIVE, { 'kernel/core/space.c' => member_write })
    assert_equal ['cap-table-private: kernel/core/space.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    definition = "struct erx_cap_table {\n\tunsigned capacity;\n};\n"
    found = evaluate(Rules::ACTIVE, { 'kernel/core/space.c' => definition })
    assert_equal ['cap-table-private: kernel/core/space.c:1'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    allowed = {
      'kernel/core/cap.c' => "#include \"erx/cap.h\"\n#include \"cap_impl.h\"\n",
      'kernel/core/cap_impl.h' => "#include \"erx/cap.h\"\nstruct erx_cap_table {\n\tunsigned capacity;\n};\n",
      'test/fixtures/cap_driver.c' => "#include \"cap_impl.h\"\n",
      'tools/fuzz/cap_fuzz.c' => "#include \"cap_impl.h\"\n",
      'include/erx/cap.h' => "typedef struct erx_cap_table erx_cap_table_t;\n",
      'kernel/core/space.c' => "void f(struct erx_cap_table *t);\nsize_t g(void) { return erx_cap_table_size(); }\n"
    }
    assert_empty evaluate(Rules::ACTIVE, allowed)
  end

  # erx_cap_slot_clear is named only in the cores, its declaration and the
  # core's host tests, so the call graph sees every caller.
  def test_only_the_cores_and_their_tests_name_the_slot_clear
    clear = [rule('cap-slot-clear-named')]
    call = "void f(void) { erx_cap_slot_clear(0, 0, 0); }\n"
    allowed = {
      Rules::CAP_CORE => call,
      'test/fixtures/cap_driver.c' => call,
      'include/erx/cap.h' => "erx_status_t erx_cap_slot_clear(erx_cap_table_t *, erx_cap_t, uint64_t);\n",
      'kernel/core/space.c' => "void erx_space_clear_caps(void) { erx_cap_slot_clear(0, 0, 0); }\n",
      'tools/fuzz/cap_fuzz.c' => call
    }
    assert_empty evaluate(clear, allowed)
    # The generated headers do not clear a slot.
    found = evaluate(clear, { Rules::CAP_SLOT_IMPL => call, 'include/erx/abi.h' => call })
    assert_equal ['include/erx/abi.h:1', "#{Rules::CAP_SLOT_IMPL}:1"],
                 found.map { |violation| "#{violation.path}:#{violation.line}" }.sort
    # The inherited tree outside the stopgap kernel is not read.
    assert_empty evaluate(clear, { 'fiasco/l4re-core/x.c' => "erx_cap_slot_clear(0, 0, 0);\n" },
                          imported: ['fiasco/l4re-core/x.c'])
  end

  # Each allowed caller of erx_cap_slot_clear passes, by a call or a tail
  # jump; a file-local function of an allowed name, any other caller and
  # a seeded violation in a graph the stack proof enforces all fail.
  def test_only_the_listed_functions_clear_a_capability_slot
    clear = rule('cap-slot-clear-callers')
    clear.callers.each do |caller|
      %w[call tail_jump].each do |reach|
        graph = Chokepoints.seeded_graph({ caller => reach }, callee: clear.callee)
        assert_empty Chokepoints.call_graph_violations([clear], graph), caller
      end
    end
    assert_empty Chokepoints.call_graph_violations(
      [clear], Chokepoints.seeded_graph({ 'erx_cap_install' => 'call' }, callee: 'erx_cap_read')
    )
    graph = Chokepoints.seeded_graph({ 'erx_pass_take' => 'call', 'cap.o:erx_cap_close' => 'tail_jump',
                                       'erx_cap_grow' => 'call' }, callee: clear.callee)
    error = assert_raises(Erx::Error) { Chokepoints.enforce_call_graph(Rules::CALL_GRAPH, graph) }
    assert_match(/2 chokepoint violation/, error.message)
    assert_match(/erx_cap_close \(cap\.o\) calls erx_cap_slot_clear/, error.message)
    assert_match(/erx_cap_grow calls erx_cap_slot_clear/, error.message)
  end

  # Another file of the capability core's own directory gets no exception:
  # the active rules refuse its include of either private header, and
  # pass it when it uses only the public one.
  def test_another_core_file_reaches_neither_private_capability_header
    found = evaluate(Rules::ACTIVE, { 'kernel/core/cap_table.c' => "#include \"cap_slot_impl.h\"\n" \
                                                                   "#include \"cap_impl.h\"\n" })
    assert_equal %w[cap-slot-private cap-table-private], found.map(&:rule).sort
    assert_empty evaluate(Rules::ACTIVE, { 'kernel/core/cap_table.c' => "#include \"erx/cap.h\"\n" })
  end
end
