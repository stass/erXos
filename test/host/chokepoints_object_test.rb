# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsObjectTest < Minitest::Test
  include ChokepointsHelper

  # The object store's records reach only the store, its header and its
  # host tests: the tree's own spellings pass, and a typedef, a pointer or
  # a sizeof only refers to a record. Every other use of a tag is refused.
  def test_object_records_are_private_to_the_store
    records = [rule('object-records-private')]
    allowed = {
      Rules::OBJECT_IMPL => "struct erx_object {\n\tint state;\n};\nstruct erx_object_store {\n};\n",
      Rules::OBJECT_CORE => "#include \"object_impl.h\"\n",
      'test/fixtures/object_driver.c' => "#include \"object_impl.h\"\n",
      'tools/fuzz/object_fuzz.c' => "#include \"object_impl.h\"\n",
      'include/erx/object.h' => "typedef struct erx_object erx_object_t;\n" \
                                "typedef struct erx_object_store erx_object_store_t;\n",
      'kernel/core/cap.c' => "void f(struct erx_object *o, const struct erx_object_store *s);\n" \
                             "size_t g(void) { return sizeof(struct erx_object); }\n"
    }
    assert_empty evaluate(records, allowed)
    found = evaluate(records, { 'kernel/core/attach.c' => "#include \"erx/object.h\"\n#include \"object_impl.h\"\n" })
    assert_equal ['object-records-private: kernel/core/attach.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    # Another core's driver is not one of the store's host tests.
    refute_empty evaluate(records, { 'test/fixtures/budget_driver.c' => "#include \"object_impl.h\"\n" })
  end

  # A new writer of the state word is refused wherever it is named: cap.c
  # may name only the slot count's removal, delete.c only the close, and
  # no other file either.
  def test_the_state_word_has_two_writers
    named = [rule('object-state-writers-named')]
    allowed = {
      Rules::OBJECT_CORE => "bool erx_object_close(erx_object_t *o) { return erx_object_cap_remove(o); }\n",
      'include/erx/object.h' => "bool erx_object_cap_remove(erx_object_t *);\nbool erx_object_close(erx_object_t *);\n",
      'test/fixtures/object_driver.c' => "(void)erx_object_close(o);\n",
      'kernel/core/cap.c' => "released = erx_object_cap_remove(object);\n",
      'kernel/core/delete.c' => "goes_on = erx_object_close(object);\n",
      'kernel/core/attach.c' => "erx_object_closed(o); erx_object_cap_removed(o);\n"
    }
    assert_empty evaluate(named, allowed)
    found = evaluate(named, { 'kernel/core/cap.c' => "x = erx_object_cap_remove(o);\ny = erx_object_close(o);\n",
                              'kernel/core/delete.c' => "z = erx_object_cap_remove(o);\n",
                              'kernel/core/space.c' => "/* erx_object_close */ w = erx_object_close(o);\n" })
    assert_equal ['kernel/core/cap.c:2', 'kernel/core/delete.c:1', 'kernel/core/space.c:1'],
                 found.map { |v| "#{v.path}:#{v.line}" }.sort
  end

  # The call-graph rules let only the slot clear count a slot out and only
  # the deletion step close an object.
  def test_only_the_named_callers_write_the_state_word
    release = rule('object-release-callers')
    close = rule('object-close-callers')
    allowed = Chokepoints.seeded_graph({ 'erx_cap_slot_clear' => 'call' }, callee: 'erx_object_cap_remove')
    assert_empty release.violations_in_graph(allowed)
    allowed = Chokepoints.seeded_graph({ 'erx_delete_step' => 'tail_jump' }, callee: 'erx_object_close')
    assert_empty close.violations_in_graph(allowed)
    refused = Chokepoints.seeded_graph({ 'erx_space_clear_caps' => 'call' }, callee: 'erx_object_cap_remove')
    assert_equal ['object-release-callers'], release.violations_in_graph(refused).map(&:rule)
    refused = Chokepoints.seeded_graph({ 'delete.o:erx_delete_step' => 'call' }, callee: 'erx_object_close')
    assert_equal ['object-close-callers'], close.violations_in_graph(refused).map(&:rule)
  end
end
