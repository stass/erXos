# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/attach_fields'

# The attachment-fields chokepoint (docs/design-kernel.md, "Chokepoint
# checks"): the tree passes, and each seeded violation fails, field by field:
# a field without its insert, an insert that links before reading the
# state, a field without its walk in the teardown, and an insert into no
# field.
class AttachFieldsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  F = Erx::AttachFields
  RECORD = 'kernel/core/object_impl.h'

  def tree
    paths = [F::ATTACH, F::DELETE, *Dir.glob(F::RECORDS, base: ROOT)]
    paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
  end

  def found(files) = F.violations(files).map(&:detail)

  def test_the_tree_passes_and_declares_the_slot_list
    files = tree
    assert_empty F.violations(files).map(&:to_s)
    assert_includes F.fields_of(RECORD, files.fetch(RECORD)).map(&:name), 'slots'
  end

  # The seed: a field added to a record with neither insert nor walk.
  def test_a_field_without_its_insert_or_walk_fails
    files = tree
    files[RECORD] = files.fetch(RECORD).sub("struct erx_object {\n", "struct erx_object {\n\tvoid *att_watched;\n")
    assert_equal ["att_watched has no insert erx_attach_object_watched in #{F::ATTACH}",
                  "att_watched has no walk (erx_object_watched) in #{F::DELETE}"], found(files)
  end

  def test_a_field_of_another_record_needs_its_own_reader
    files = tree.merge('kernel/core/budget_impl.h' => "struct erx_budget {\n\terx_dlink_t att_charged;\n};\n")
    files[F::ATTACH] = files.fetch(F::ATTACH) +
                       "\nerx_status_t\nerx_attach_budget_charged(erx_object_t *o)\n{\n\tif (erx_object_state(o) != 1)\n\t\treturn (1);\n\treturn (0);\n}\n"
    assert_equal ["att_charged has no walk (erx_budget_charged) in #{F::DELETE}"], found(files)
  end

  # A field name two records share needs an insert for each record.
  def test_one_insert_does_not_serve_two_records
    files = tree.merge('kernel/core/space_impl.h' => "struct erx_space {\n\tvoid *att_slots;\n};\n")
    files[F::DELETE] = files.fetch(F::DELETE) + "\nstatic void\nwalk(void)\n{\n\t(void)erx_space_slots(0);\n}\n"
    assert_equal ["att_slots has no insert erx_attach_space_slots in #{F::ATTACH}"], found(files)
  end
  
  def test_an_insert_that_links_before_it_reads_the_state_fails
    files = tree
    attach = files.fetch(F::ATTACH)
    files[F::ATTACH] = attach.sub("\tif (erx_object_state(object) != ERX_OBJ_LIVE)\n\t\treturn (ERX_ESTALE);\n\t*nextp = erx_object_slots(object);\n",
                                  "\t*nextp = erx_object_slots(object);\n\tif (erx_object_state(object) != ERX_OBJ_LIVE)\n\t\treturn (ERX_ESTALE);\n")
    refute_equal attach, files[F::ATTACH]
    assert_equal ['erx_attach_object_slots does not call erx_object_state before anything else'], found(files)
  end

  def test_a_comment_naming_the_walk_does_not_count
    files = tree
    delete = files.fetch(F::DELETE)
    files[F::DELETE] = delete.gsub('erx_object_slots(', 'erx_object_slot_head(') + "/* erx_object_slots(o) */\n"
    assert_equal ["att_slots has no walk (erx_object_slots) in #{F::DELETE}"], found(files)
  end

  def test_an_insert_into_no_field_fails
    files = tree
    files[F::ATTACH] = files.fetch(F::ATTACH) + "\nvoid\nerx_attach_object_stray(erx_object_t *o)\n{\n\t(void)erx_object_state(o);\n}\n"
    assert_equal ['erx_attach_object_stray inserts into no declared attachment field'], found(files)
  end
end
