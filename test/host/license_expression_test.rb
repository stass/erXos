# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/license_expression'

class LicenseExpressionTest < Minitest::Test
  def select(expression, restricted: false)
    Erx::LicenseExpression.select(expression, allow_restricted: restricted)
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

  def test_unknown_and_malformed_input_remains_fail_closed
    ['NOASSERTION', 'NONE', 'MIT AND Unknown-License', 'MIT XOR ISC', 'MIT OR',
     '(MIT', 'MIT)', '(MIT OR ISC) WITH exception', "MIT\nOR ISC", '('*33 + 'MIT' + ')'*33,
     'MIT OR '*200 + 'ISC'].each do |expression|
      assert_raises(Erx::Error) { select(expression) }
    end
    assert_equal ['MIT'], select('Unknown-License OR MIT').fetch('grants')
  end
end
