# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/license_expression'

class LicenseExpressionTest < Minitest::Test
  def select(expression, restricted: false, font_data: false)
    Erx::LicenseExpression.select(expression, allow_restricted: restricted, font_data: font_data)
  end

  def test_or_selects_one_permissive_branch_in_either_order
    ['BSD-3-Clause OR GPL-2.0-only', 'GPL-2.0-only OR BSD-3-Clause'].each do |expression|
      assert_equal ['BSD-3-Clause'], select(expression).fetch('grants')
      assert_equal ['BSD-3-Clause'], select(expression, restricted: true).fetch('grants')
    end
  end

  def test_and_precedence_and_parentheses_preserve_all_obligations
    assert_equal ['MIT', 'ISC'], select('(MIT OR GPL-2.0-only) AND ISC').fetch('grants')
    assert_equal ['MIT'], select('MIT OR BSD-2-Clause AND GPL-2.0-only').fetch('grants')
    assert_raises(Erx::Error) { select('(MIT OR BSD-2-Clause) AND GPL-2.0-only') }
    assert_equal ['MIT', 'GPL-2.0-only'], select('MIT AND GPL-2.0-only', restricted: true).fetch('grants')
  end

  def test_exceptions_are_attached_to_their_own_grant
    assert_equal ['Apache-2.0 WITH LLVM-exception'], select('Apache-2.0 WITH LLVM-exception').fetch('grants')
    assert_raises(Erx::Error) { select('MIT WITH Unknown-exception') }
    assert_raises(Erx::Error) { select('GPL-3.0-or-later WITH GCC-exception-3.1') }
    assert_equal ['GPL-3.0-or-later WITH GCC-exception-3.1'],
                 select('GPL-3.0-or-later WITH GCC-exception-3.1', restricted: true).fetch('grants')
  end

  def test_the_public_domain_dedication_is_a_permitted_grant_and_no_other_reference_is
    assert_equal ['BSD-2-Clause', 'LicenseRef-DJB-public-domain'],
                 select('BSD-2-Clause AND LicenseRef-DJB-public-domain').fetch('grants')
    assert_raises(Erx::Error) { select('LicenseRef-Someone-public-domain') }
  end

  # erx-lvgl's liblvgl.a: MIT code and OFL-1.1 font data. OFL-1.1 is admitted for an input that
  # states its OFL content is font data, and for no other input.
  def test_ofl_is_admitted_only_for_an_input_that_states_font_data
    lvgl = 'MIT AND OFL-1.1'
    assert_equal ['MIT', 'OFL-1.1'], select(lvgl, font_data: true).fetch('grants')
    assert_raises(Erx::Error) { select(lvgl) }
    assert_raises(Erx::Error) { select('OFL-1.1') }
    assert_raises(Erx::Error) { select('OFL-1.1', font_data: false) }
    assert_raises(Erx::Error) { select('OFL-1.1', font_data: 'yes') }
    assert_equal ['MIT', 'OFL-1.1'], select(lvgl, restricted: true).fetch('grants')
  end

  def test_the_font_data_statement_admits_no_other_restricted_licence
    ['MIT AND OFL-1.1 AND GPL-2.0-only', 'GPL-3.0-or-later', 'OFL-1.1 AND MPL-2.0', 'LGPL-2.1-only AND OFL-1.1',
     'GPL-2.0-only WITH Classpath-exception-2.0'].each do |expression|
      assert_raises(Erx::Error, expression) { select(expression, font_data: true) }
    end
    assert_equal ['MIT'], select('MIT OR GPL-2.0-only', font_data: true).fetch('grants')
  end

  def test_unknown_and_malformed_input_remains_fail_closed
    ['NOASSERTION', 'NONE', 'MIT AND Unknown-License', 'MIT XOR ISC', 'MIT OR',
     '(MIT', 'MIT)', '(MIT OR ISC) WITH exception', "MIT\nOR ISC", '('*33 + 'MIT' + ')'*33,
     'MIT OR '*200 + 'ISC'].each do |expression|
      assert_raises(Erx::Error) { select(expression) }
    end
    assert_equal ['MIT'], select('Unknown-License OR MIT').fetch('grants')
  end
end
