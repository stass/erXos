# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsDomTest < Minitest::Test
  include ChokepointsHelper

  CONFIGURED_CALL = "status = erx_dom_plan_configured(&lib->view, id, row, &plan);\n"

  # Manifest startup (dom_boot.c) is the one caller of the configured entry on
  # the target: the apply phase, which applies every plan, and the NIF, which a
  # domain facet reaches, are refused, as is a call of the partial entry from
  # manifest startup, which has no caller yet.
  def test_only_manifest_startup_calls_the_configured_entry
    entries = [rule('dom-manifest-entries'), rule('dom-partial-entry-uncalled')]
    assert_empty evaluate(entries, { Rules::DOM_BOOT => CONFIGURED_CALL,
                                     Rules::DOM_HOST_PLANNER => CONFIGURED_CALL,
                                     Rules::DOM_APPLY => "/* not erx_dom_plan_configured */\nx;\n" })
    found = evaluate(entries, { Rules::DOM_APPLY => "x;\n#{CONFIGURED_CALL}" })
    assert_equal ['dom-manifest-entries: liberx/system/dom_apply.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    refute_empty evaluate(entries, { Rules::DOM_NIF => CONFIGURED_CALL })
    # The applying entry is manifest authority too: a NIF that hands it a row is refused.
    refute_empty evaluate(entries, { Rules::DOM_NIF => "status = erx_dom_lib_configured(lib, id, row, &created);\n" })
    assert_empty evaluate(entries, { Rules::DOM_LIB_HEADER => "erx_status_t erx_dom_lib_configured(void);\n" })
    found = evaluate(entries, { Rules::DOM_BOOT => "status = erx_dom_plan_partial(&lib->view, id, row, &plan);\n" })
    assert_equal ['dom-partial-entry-uncalled'], found.map(&:rule)
  end
end
