# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsMapTest < Minitest::Test
  include ChokepointsHelper

  # A record's protection and ceiling are written only in the core: no other
  # file can define the record, so no other file can reach its members.
  def test_only_the_map_core_defines_a_mapping_record
    map = [rule('map-records-private')]
    allowed = {
      Rules::MAP_CORE => "struct erx_mapping {\n\tuint8_t ceiling;\n};\nstatic void f(struct erx_mapping *m);\n",
      'include/erx/map.h' => "typedef struct erx_mapping erx_mapping_t;\nstruct erx_mapping_view {\n\tint kind;\n};\n",
      'test/fixtures/map_driver.c' => "size_t g(void) { return sizeof(struct erx_mapping); }\n",
      'fiasco/kernel/src/erx/map.cpp' => "void f(erx_mapping *m, erx_mapping &n, int);\n"
    }
    assert_empty evaluate(map, allowed)
    found = evaluate(map, { 'kernel/core/fault.c' => "#include \"erx/map.h\"\nstruct erx_mapping { int ceiling; };\n" })
    assert_equal ['map-records-private: kernel/core/fault.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
  end

  # What a plan will write is the core's, so no other file can change a ceiling
  # between a plan and its apply.
  def test_only_the_map_core_names_the_core_members
    members = [rule('map-core-members')]
    allowed = { Rules::MAP_CORE => "plan->core_segs[0].source = 0;\n",
                'include/erx/map.h' => "\terx_mapping_t *core_root;\n",
                'test/fixtures/map_driver.c' => "plan.nspares = 1; score_segs = 0;\n" }
    assert_empty evaluate(members, allowed)
    found = evaluate(members, { 'kernel/core/fault.c' => "\nplan.core_segs[0].attrs.ceiling = 7;\n" })
    assert_equal ['map-core-members: kernel/core/fault.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
  end
  end
