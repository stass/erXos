# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsTest < Minitest::Test
  include ChokepointsHelper

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
    text = "#include <l4/sys/ipc.h>\nint f(void) { l4_ipc_call(); __asm__(\"svc #0x4552\"); }\n"
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
    glue = Erx::Chokepoints::Pending.new(name: 'seeded', rule: 'seeded', design: 'seeded', reason: 'seeded',
                                         awaits: ['fiasco/kernel/src/erx/**/*'],
                                         existing: ['fiasco/kernel/src/erx/erx_probe.cpp'])
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
    %w[test/fixtures/cap_driver.c test/fixtures/cap_churn.c tools/fuzz/cap_fuzz.c].each do |test|
      assert_empty evaluate([rule('core-records-private')], { test => "#include \"cap_slot_impl.h\"\n" })
      assert_empty evaluate([rule('core-records-private')], { test => "#include \"cap_impl.h\"\n" })
      refute_empty evaluate([rule('core-records-private')], { test => "#include \"budget_impl.h\"\n" })
    end
  end

  # The rule names the cores' private headers, not every header whose name
  # ends in _impl.h: an import below kernel/, which the rules read as
  # erXos's own C, may include its own (BLAKE3's blake3_impl.h) and is
  # refused a core's, by any path and in any case.
  def test_core_records_private_names_only_the_cores_headers
    private_rule = rule('core-records-private')
    blake3 = 'kernel/crypto/blake3/blake3.c'
    assert_empty evaluate([private_rule], { blake3 => "#include \"blake3_impl.h\"\n" })
    assert_empty evaluate([private_rule], { 'liberx/x.c' => "#include <vendor/other_impl.h>\n" })
    refute_empty evaluate([private_rule], { blake3 => "#include \"cap_impl.h\"\n" })
    refute_empty evaluate([private_rule], { blake3 => "#include \"kernel/generated/cap_slot_impl.h\"\n" })
    refute_empty evaluate([private_rule], { 'liberx/x.c' => "#include <core/BUDGET_impl.h>\n" })
    # Every hand-written private header and every private layout's
    # generated header is among those the rule names; the import's is not.
    known = [*Rules::GROUPS.values.flat_map(&:private_headers), *Rules::PRIVATE_LAYOUTS.map(&:private_header)]
    assert_empty known - Rules::PRIVATE_HEADERS
    refute_includes Rules::PRIVATE_HEADERS, 'kernel/crypto/blake3/blake3_impl.h'
  end

  # A private header is any *_impl.h below kernel/ outside an import, so a
  # core directory added later (kernel/sched) is covered with no entry,
  # and a header in a directory with an ORIGIN.md is the import's own.
  def test_private_headers_are_every_core_impl_header_outside_imports
    listing = %w[kernel/core/cap_impl.h kernel/sched/run_IMPL.h kernel/generated/cap_slot_impl.h
                 kernel/arch/aarch64/deep/x_impl.h kernel/crypto/blake3/ORIGIN.md
                 kernel/crypto/blake3/blake3_impl.h kernel/crypto/blake3/sub/y_impl.h
                 kernel/crypto/blake3x/z_impl.h liberx/w_impl.h kernel/core/cap.h]
    assert_equal %w[kernel/arch/aarch64/deep/x_impl.h kernel/core/cap_impl.h kernel/crypto/blake3x/z_impl.h
                    kernel/generated/cap_slot_impl.h kernel/sched/run_IMPL.h],
                 Rules.private_headers(listing).sort
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

  def test_a_call_graph_rule_seeds_only_calls_and_tail_jumps
    error = assert_raises(Erx::Error) do
      Chokepoints::Callers.new(name: 'x', rule: 'x', design: 'x', callee: 'f', callers: [], seed: { 'g' => 'jump' })
    end
    assert_match(/unknown reach/, error.message)
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
