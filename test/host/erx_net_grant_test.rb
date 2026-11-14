# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the grant's admission, test/erlang/erx_net_grant_tests.erl:
# erx_net_admit:request/2 and mint/2, and a grant that acts only on what they admit.
# Then seeded faults, each of which must fail: an admission that takes any reply target, a
# pid or a reply alias of another domain, as a grant that takes a caller-supplied owner
# would; a mint that admits the system domain as a grantee; a grant that starts without
# exporting itself; a sockets limit one too wide; an open that records nothing; and a grant
# that outlives its connection to the grantee.
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

  def test_a_system_domain_grantee_is_caught
    output = refute_erx_net_eunit(:erx_net_grant_tests,
                                  fault: { 'erx_net_admit' => ['case Grantee =:= System of', 'case Grantee =:= -1 of'] })
    assert_case_failed(:mint_test, output)
  end

  def test_an_answer_without_the_export_is_caught
    unexported = ['case Exports:export(self(), [send], Grantee) of', 'case element(1, {ok, Exports}) of']
    output = refute_erx_net_eunit(:erx_net_grant_tests, fault: { 'erx_net_grant' => unexported })
    assert_case_failed(:minted_exported, output)
  end

  # A sockets limit that admits one socket past it: the grant at its limit opens a second
  # socket.
  def test_a_sockets_limit_off_by_one_is_caught
    output = refute_erx_net_eunit(:erx_net_grant_tests,
                                  fault: { 'erx_net_grant_core' => ['map_size(Open) >= SocketsLimit', 'map_size(Open) > SocketsLimit'] })
    assert_case_failed(:sockets_limit, output)
  end

  # An open that starts its socket but keeps the sockets it had before it, so it records
  # nothing: the grant holding it opens another.
  def test_an_open_that_records_nothing_is_caught
    unrecorded = ['{ok, Socket, Token, S#{sockets := Sockets}}',
                  '{ok, Socket, Token, S#{sockets := element(1, {Sockets0, Sockets})}}']
    output = refute_erx_net_eunit(:erx_net_grant_tests, fault: { 'erx_net_grant' => unrecorded })
    assert_case_failed(:sockets_limit, output)
  end

  def test_a_grant_outliving_its_connection_is_caught
    output = refute_erx_net_eunit(:erx_net_grant_tests,
                                  fault: { 'erx_net_grant' => ['{stop, {shutdown, connection_ended}, S};', '{noreply, S};'] })
    assert_case_failed(:grant_ends_with_connection, output)
  end

  private

  # The case Name failed: on EUnit's own line for it, or on the "in function" line that
  # follows a failure, since a grant's error report can land between the case's
  # description and its "*failed*" when the cleanup kills a grant the fault kept alive.
  def assert_case_failed(name, output)
    assert_match(/\b#{name}\b[^\n]*\*failed\*|\*failed\*\s+in function erx_net_grant_tests:#{name}\//, output)
  end
end
