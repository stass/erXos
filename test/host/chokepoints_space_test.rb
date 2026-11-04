# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsSpaceTest < Minitest::Test
  include ChokepointsHelper

  # The space core's record is defined only in its source: the header's
  # typedef, pointers and sizeof refer to it, and every definition
  # elsewhere is refused.
  def test_space_records_are_private_to_the_space_core
    space = [rule('space-records-private')]
    allowed = {
      Rules::SPACE_CORE => "struct erx_space {\n\tint run;\n};\nstatic void f(struct erx_space *s);\n",
      'include/erx/space.h' => "typedef struct erx_space erx_space_t;\nstruct erx_space_facts {\n\tint run;\n};\n",
      'test/fixtures/space_driver.c' => "size_t g(void) { return sizeof(struct erx_space); }\n",
      'fiasco/kernel/src/erx/space.cpp' => "void f(erx_space *s, erx_space &t, int);\n"
    }
    assert_empty evaluate(space, allowed)
    found = evaluate(space, { 'kernel/core/stop.c' => "#include \"erx/space.h\"\nstruct erx_space { int run; };\n" })
    assert_equal ['space-records-private: kernel/core/stop.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
  end

  # Going back up reads a parent pointer and never counts it, so a call of
  # erx_space_parent outside the core and its fuzz target is refused.
  def test_only_the_space_core_reads_a_parent_pointer
    parent = [rule('space-parent-callers')]
    allowed = { Rules::SPACE_CORE => "erx_space_parent(const erx_space_t *s);\n",
                'include/erx/space.h' => "erx_space_t *erx_space_parent(const erx_space_t *);\n",
                'tools/fuzz/space_fuzz.c' => "s = erx_space_parent(s);\n" }
    assert_empty evaluate(parent, allowed)
    found = evaluate(parent, { 'kernel/core/stop.c' => "\nerx_object_ref(erx_space_parent(s));\n" })
    assert_equal ['space-parent-callers: kernel/core/stop.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
  end

  # A space's count of holds reaches only the host tests, never inspection.
  def test_only_the_host_tests_read_a_spaces_holds
    holds = [rule('space-holds-callers')]
    allowed = { Rules::SPACE_CORE => "erx_space_holds(const erx_space_t *s);\n",
                'test/fixtures/space_driver.c' => "n = erx_space_holds(s);\n",
                'tools/fuzz/space_fuzz.c' => "n = erx_space_holds(s);\n" }
    assert_empty evaluate(holds, allowed)
    found = evaluate(holds, { 'kernel/core/inspect.c' => "\nn = erx_space_holds(s);\n" })
    assert_equal ['space-holds-callers: kernel/core/inspect.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
  end
end
