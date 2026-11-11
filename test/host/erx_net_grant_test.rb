# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the grant's admission, test/erlang/erx_net_grant_tests.erl:
# erx_net_admit:request/2 and mint/2, and a grant that acts only on what they admit.
# Then a seeded fault: an admission that takes any reply target, a pid or a reply alias of
# another domain, as a grant that takes a caller-supplied owner would, must let the
# foreign-owner and foreign-alias cases through and fail.
class ErxNetGrantTest < Minitest::Test
  include ErxNetEunit

  OWNER_CHECK = 'case domain(Pid) =:= Grantee andalso domain(Alias) =:= Grantee of'
  ANY_OWNER = 'case true of'

  def test_grant_admission_passes_under_eunit
    assert_erx_net_eunit(:erx_net_grant_tests)
  end

  def test_a_reply_target_of_another_domain_is_caught
    output = refute_erx_net_eunit(:erx_net_grant_tests, fault: { 'erx_net_admit' => [OWNER_CHECK, ANY_OWNER] })
    assert_match(/third_domain_unknown|third_domain_alias_unknown|remote_foreign_owner_dropped/, output)
  end
end
