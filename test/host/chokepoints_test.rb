# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/chokepoint_rules'

class ChokepointsTest < Minitest::Test
  Rules = Erx::ChokepointRules
  Chokepoints = Erx::Chokepoints
  ROOT = File.expand_path('../..', __dir__)
  # The capability core's host tests in the tree.
  CAP_TESTS = %w[test/fixtures/cap_driver.c test/fixtures/cap_churn.c tools/fuzz/cap_fuzz.c].freeze

  def evaluate(rules, files, imported: [])
    Chokepoints.violations(rules, names: files.keys.sort, imported: ->(path) { imported.include?(path) },
                                  read: ->(path) { files.fetch(path) })
  end

  def rule(name) = Rules::ALL.find { |candidate| candidate.name == name }

  # Every active rule catches every file of its seed, each alone, so no
  # seed passes on the strength of another file's violation.
  def test_every_active_rule_fails_on_each_seeded_file
    refute_empty Rules::ACTIVE
    Rules::ACTIVE.each do |active|
      active.seed.each do |path, text|
        found = evaluate([active], { path => text })
        refute_empty found, "#{active.name} missed its seed #{path}"
        assert(found.all? { |violation| violation.rule == active.name && violation.path == path })
      end
    end
  end

  def test_an_active_rule_without_a_seed_cannot_be_declared
    error = assert_raises(Erx::Error) do
      Chokepoints::Forbidden.new(name: 'unseeded', rule: 'x', design: 'x', scope: Rules::ERXOS_C, pattern: /x/,
                                 seed: {})
    end
    assert_match(/no seeded violation/, error.message)
  end

  def test_rule_names_are_distinct
    names = Rules::ALL.map(&:name)
    assert_equal names.uniq, names
  end

  def test_fiasco_backend_may_speak_fiasco
    text = "#include <l4/sys/ipc.h>\nint f(void) { l4_ipc_call(); __asm__(\"svc #0\"); }\n"
    assert_empty evaluate(Rules::ACTIVE, { 'liberx/backend/fiasco/trap.c' => text })
    assert_equal %w[fiasco-headers-in-backend fiasco-symbols-in-backend one-erx-trap],
                 evaluate(Rules::ACTIVE, { 'kernel/core/trap.c' => text }).map(&:rule).uniq.sort
  end

  def test_only_the_abi_trap_is_allowed_in_the_erx_backend
    site = 'liberx/backend/erx/arch/aarch64/generated/calls.c'
    trap = "#{Rules::TRAP_OPCODE} ##{Rules::TRAP_IMMEDIATE}"
    assert_empty evaluate(Rules::ACTIVE, { site => "void f(void) { __asm__ volatile(\"#{trap}\"); }\n" })
    %w[hvc smc].each do |opcode|
      refute_empty evaluate(Rules::ACTIVE, { site => "void f(void) { __asm__(\"#{opcode} #0\"); }\n" })
    end
    refute_empty evaluate(Rules::ACTIVE, { site => "void f(void) { __asm__(\".inst 0xd4000001\"); }\n" })
    refute_empty evaluate(Rules::ACTIVE, { 'kernel/core/x.c' => "void f(void) { __asm__(\"#{trap}\"); }\n" })
  end

  def test_comments_are_not_code_but_splices_and_trigraphs_are
    assert_empty evaluate(Rules::ACTIVE, { 'kernel/core/a.c' => "/* l4_ipc_call svc #0 */\n// #include <l4/sys/x.h>\n" })
    refute_empty evaluate(Rules::ACTIVE, { 'kernel/core/b.c' => "int x = l4\\\n_thing;\n" })
    refute_empty evaluate([rule('include-form')], { 'kernel/core/c.c' => "??=include HIDDEN\n" })
    refute_empty evaluate([rule('include-form')], { 'kernel/core/d.c' => "%:include HIDDEN\n" })
    # A comment opener inside a string is text, and the string's content stays.
    refute_empty evaluate(Rules::ACTIVE, { 'kernel/core/e.c' => "char *s = \"/*\"; int l4_y; /* */\n" })
  end

  def test_unreadable_c_fails_closed
    found = evaluate([rule('fiasco-symbols-in-backend')], { 'kernel/core/a.c' => "/* never closed\nl4_x;\n" })
    assert_match(/unterminated comment/, found.first.detail)
    found = evaluate([rule('include-form')], { 'fiasco/kernel/src/erx/a.cpp' => "auto s = R\"x(*/)x\";\n" })
    assert_match(/raw string/, found.first.detail)
  end

  # Each text here once read as a comment while a compiler builds the call.
  def test_literal_prefixes_and_digits_in_names_hide_no_code
    call = 'void f() { l4_ipc_call(0, 0, 0, 0); }'
    {
      'fiasco/kernel/src/erx/a.cpp' => "char c = u8'a'; const char *s = \"'//\"; #{call}\n",
      'kernel/core/b.c' => "#define D(x)\nD(x1'a') const char *s = \"'//\"; #{call}\n",
      'fiasco/kernel/src/erx/c.cpp' => "const char8_t *s = u8R\"(\" // )\"; #{call}\n",
      'fiasco/kernel/src/erx/d.cpp' => "// note ??/\n#{call}\n",
      'kernel/core/E.C' => "#{call}\n"
    }.each do |path, text|
      refute_empty evaluate(Rules::ACTIVE, { path => text }), path
    end
  end

  def test_unpreprocessed_assembler_is_not_spliced
    refute_empty evaluate(Rules::ACTIVE, { 'liberx/a.s' => "// x\\\nsvc #0\n" })
  end

  def test_a_pending_scope_fails_on_a_new_file_and_on_a_stale_exemption
    glue = rule('glue-imports')
    assert_empty evaluate([glue], { 'fiasco/kernel/src/erx/erx_probe.cpp' => '' })
    refute_empty evaluate([glue], { 'fiasco/kernel/src/erx/erx_probe.cpp' => '', 'fiasco/kernel/src/erx/ipc.cpp' => '' })
    assert_match(/no longer listed/, evaluate([glue], { 'kernel/core/a.c' => '' }).first.detail)
    assert_raises(Erx::Error) do
      Chokepoints::Pending.new(name: 'x', rule: 'x', design: 'x', awaits: [], reason: 'x')
    end
  end

  def test_digit_separators_are_numbers
    assert_empty evaluate(Rules::ACTIVE, { 'fiasco/kernel/src/erx/a.cpp' => "long x = 0xffff'0000; // it's\n" })
  end

  def test_include_form_refuses_non_header_and_climbing_includes
    form = [rule('include-form')]
    assert_empty evaluate(form, { 'kernel/core/a.c' => "#include <stdint.h>\n#include \"erx/abi.h\"\n" })
    assert_empty evaluate(form, { 'fiasco/kernel/src/erx/a.cpp' => "#include <cstdio>\n" })
    refute_empty evaluate(form, { 'kernel/core/a.c' => "#include <cstdio>\n" })
    refute_empty evaluate(form, { 'kernel/core/a.c' => "#include \"table.inc\"\n" })
    refute_empty evaluate(form, { 'kernel/core/a.c' => "#include \"../../fiasco/kernel/src/kern/x.h\"\n" })
    refute_empty evaluate(form, { 'kernel/core/a.c' => "#  include_next <x.h> extra\n" })
  end

  def test_scope_reads_only_c_family_and_own_or_glue_files
    text = "l4_ipc_call();\n"
    assert_empty evaluate(Rules::ACTIVE, { 'abi/notes.txt' => text, 'tools/a.rb' => text })
    assert_empty evaluate(Rules::ACTIVE, { 'fiasco/kernel/src/kern/a.cpp' => text },
                          imported: ['fiasco/kernel/src/kern/a.cpp'])
    refute_empty evaluate(Rules::ACTIVE, { 'fiasco/kernel/src/erx/a.cpp' => text },
                          imported: ['fiasco/kernel/src/erx/a.cpp'])
  end

  def test_core_records_are_private_to_the_cores
    include_impl = "#include \"cap_impl.h\"\n"
    assert_empty evaluate([rule('core-records-private')], { 'kernel/core/cap.c' => include_impl })
    refute_empty evaluate([rule('core-records-private')], { 'liberx/x.c' => include_impl })
    refute_empty evaluate([rule('core-records-private')], { 'liberx/x.c' => "#import \"cap_impl.h\"\n" })
    # The budget core's host driver may include its core's header, no other.
    driver = Rules::BUDGET_DRIVER
    assert_empty evaluate([rule('core-records-private')], { driver => "#include \"budget_impl.h\"\n" })
    refute_empty evaluate([rule('core-records-private')], { driver => "#include \"cap_impl.h\"\n" })
    refute_empty evaluate([rule('core-records-private')], { driver => "#include \"cap_slot_impl.h\"\n" })
    # The capability core's host tests, named after it, may include its
    # table header and its generated slot header, no other.
    CAP_TESTS.each do |test|
      assert_empty evaluate([rule('core-records-private')], { test => "#include \"cap_slot_impl.h\"\n" })
      assert_empty evaluate([rule('core-records-private')], { test => "#include \"cap_impl.h\"\n" })
      refute_empty evaluate([rule('core-records-private')], { test => "#include \"budget_impl.h\"\n" })
    end
  end

  # The budget core's records reach only the core, its header and its
  # driver: the tree's own spellings pass, and a near name, a forward
  # declaration, a typedef, a pointer, a reference or a sizeof only refers
  # to the record. Every other use of its tag is refused.
  def test_budget_records_are_private_to_the_budget_core
    budget = [rule('budget-records-private')]
    allowed = {
      Rules::BUDGET_IMPL => "struct erx_budget {\n\tint used;\n};\nstruct erx_reserve\n{\n};\n",
      'kernel/core/budget.c' => "#include \"budget_impl.h\"\n",
      Rules::BUDGET_DRIVER => "#include \"budget_impl.h\"\n",
      'include/erx/budget.h' => "typedef struct erx_budget erx_budget_t;\nstruct erx_reserve;\n" \
                                "struct erx_budget_counters {\n\tint used;\n};\n",
      'kernel/core/kalloc.c' => "void f(const struct erx_budget *b, struct erx_reserve *r);\n" \
                                "size_t g(void) { return sizeof(struct erx_budget); }\n",
      'fiasco/kernel/src/erx/budget.cpp' => "void f(erx_reserve &r, erx_budget *, int);\n"
    }
    assert_empty evaluate(budget, allowed)
    found = evaluate(budget, { 'kernel/core/kalloc.c' => "#include \"erx/x.h\"\n  #  include \"budget_impl.h\"\n" })
    assert_equal ['budget-records-private: kernel/core/kalloc.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    # A definition with its brace on a later line is reported where its
    # tag ends the line.
    found = evaluate(budget, { 'fiasco/kernel/src/kern/split.h' => "struct erx_reserve\n{\n\tlong charged;\n};\n" })
    assert_equal [1], found.map(&:line)
    # The inherited tree outside the stopgap kernel is not read.
    assert_empty evaluate(budget, { 'fiasco/l4re-core/x.c' => "#include \"budget_impl.h\"\n" },
                          imported: ['fiasco/l4re-core/x.c'])
    refute_empty evaluate(budget, { 'fiasco/kernel/src/kern/x.cpp' => "#include \"budget_impl.h\"\n" },
                          imported: ['fiasco/kernel/src/kern/x.cpp'])
  end

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
    assert_equal({ 'erx_cap_slot' => Rules::CAP_CORE }, owners)
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

  # Every call-graph rule refuses each seeded function alone, and the text
  # evaluation leaves it to the stack proof.
  def test_every_call_graph_rule_fails_on_each_seeded_function
    refute_empty Rules::CALL_GRAPH
    Rules::CALL_GRAPH.each do |callers|
      callers.seed.each do |function, reach|
        graph = Chokepoints.seeded_graph({ function => reach }, callee: callers.callee)
        found = Chokepoints.call_graph_violations([callers], graph)
        assert_equal [callers.name], found.map(&:rule), "#{callers.name} missed its seed #{function}"
      end
      assert_empty evaluate([callers], { 'kernel/core/x.c' => "void f(void) { #{callers.callee}(); }\n" })
    end
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

  def test_a_call_graph_rule_seeds_only_calls_and_tail_jumps
    error = assert_raises(Erx::Error) do
      Chokepoints::Callers.new(name: 'x', rule: 'x', design: 'x', callee: 'f', callers: [], seed: { 'g' => 'jump' })
    end
    assert_match(/unknown reach/, error.message)
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

  def test_a_pending_rule_fails_once_its_site_lands
    assert_empty evaluate([rule('vector-route')], { 'kernel/core/watchdog.c' => '' })
    found = evaluate([rule('vector-route')], { 'fiasco/kernel/src/erx/entry.cpp' => '' })
    assert_equal ['vector-route'], found.map(&:rule)
    assert_match(/pending rule/, found.first.detail)
  end

  def test_an_elsewhere_rule_requires_its_seeding_test
    elsewhere = rule('core-archive-imports')
    assert_empty evaluate([elsewhere], { elsewhere.test => '' })
    refute_empty evaluate([elsewhere], { 'test/host/other_test.rb' => '' })
  end

  def test_enforce_reads_links_only_to_listed_files
    Dir.mktmpdir('erx-chokepoints-') do |root|
      FileUtils.mkdir_p(File.join(root, 'kernel/core'))
      File.write(File.join(root, 'outside.c'), "l4_x;\n")
      File.symlink('../../outside.c', File.join(root, 'kernel/core/link.c'))
      error = assert_raises(Erx::Error) do
        Chokepoints.enforce(Rules::ACTIVE, root: root, names: ['kernel/core/link.c'], imported: ->(_path) { false })
      end
      assert_match(/not a listed regular file/, error.message)
      error = assert_raises(Erx::Error) do
        Chokepoints.enforce(Rules::ACTIVE, root: root, names: ['kernel/core/link.c', 'outside.c'],
                                           imported: ->(_path) { false })
      end
      assert_match(%r{fiasco-symbols-in-backend: kernel/core/link.c:1}, error.message)
    end
  end
end
