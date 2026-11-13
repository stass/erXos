# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The start table's chokepoints (docs/design-apps.md, AP1 and AP2): erx_starter reaches
# erx_domain only through start_session/2, stop/2 and the handle's accessors, and calls
# nothing through a variable module or apply; only erx_console and erx_starter_keeper call
# start_session/2; only erx_starter names display or default_display beside a start.
class AppsChokepointsTest < Minitest::Test
  include ChokepointsHelper

  STARTER = 'erlang/apps/erx_starter/src/erx_starter.erl'
  KEEPER = 'erlang/apps/erx_starter/src/erx_starter_keeper.erl'
  CONSOLE = 'erlang/apps/erx/src/erx_console.erl'
  OTHER = 'erlang/apps/erx/src/erx_session.erl'
  START = "s(P) -> erx_domain:start_session(P, \#{}).\n"

  RULES = %w[starter-reach start-callers start-display].freeze

  def found(files) = erlang_found(RULES, files)

  def test_the_tree_passes
    files = erlang_tree
    assert_empty evaluate(RULES.map { |name| rule(name) }, files).map(&:to_s)
  end

  def test_the_starter_reaches_erx_domain_only_through_its_calls
    assert_equal [['starter-reach', KEEPER, 2]],
                 found(KEEPER => "%% erx_domain:create(S) in a comment is not code\nc(S) -> erx_domain:create(S).\n")
    {
      'another call' => "i(D) -> erx_domain:info(D).\n",
      'the node' => "n(D) -> erx_domain:node(D).\n",
      'a name the wait for a display begins' => "w(D) -> erx_domain:display_settled_all(D).\n",
      'an introduction' => "i(A, B) -> erx_domain:introduce(A, B).\n",
      'a module atom' => "m() -> M = erx_domain, M.\n",
      'a variable module' => "c(M, S) -> M:create(S).\n",
      'a macro module' => "c(S) -> ?DOMAIN:create(S).\n",
      'a variable fun' => "c(M) -> fun M:create/1.\n",
      'an apply' => "c(F, A) -> apply(erx_starter_row, F, A).\n",
      'an erlang:apply fun' => "c() -> fun erlang:apply/3.\n"
    }.each do |form, source|
      assert_equal [['starter-reach', STARTER, 1]], found(STARTER => source), form
    end
    # An import from erx_domain, or the service's name, breaks both rules: either lets a
    # session start without the start_session call.
    ['-import(erx_domain, [create/1]).', 'c() -> gen_server:call(erx_domain_srv, x).'].each do |source|
      assert_equal [['starter-reach', STARTER, 1], ['start-callers', STARTER, 1]], found(STARTER => "#{source}\n"), source
    end
  end

  def test_the_starter_calls_and_ordinary_forms_pass
    allowed = <<~'ERL'
      -moduledoc """
      Calls erx_domain:create/1 never; this doc string is not code.
      """.
      -spec k(pos_integer(), erx_domain:spec(), atom()) -> erx_domain:domain().
      k(P, S, D) ->
          {ok, H} = erx_domain:start_session(P, S\#{display => D}),
          link(erx_domain:pid(H)), _ = erx_domain:id(H),
          F = fun erx_domain:stop/2, ok = ?MODULE:apply_text(<<>>),
          _ = erx_domain:display_settled(<<"screen">>), _ = erx_domain:system_namespace(),
          <<N:16, _:N/binary>> = S, #{k := V} = S,
          try F(H, normal) catch C:R:St -> erlang:raise(C, R, St) end.
    ERL
    assert_empty found(KEEPER => allowed)
  end

  def test_only_the_console_and_the_keeper_start_a_session
    assert_empty found(CONSOLE => START)
    assert_empty found(KEEPER => START)
    assert_equal [['start-callers', OTHER, 1]], found(OTHER => START)
    assert_equal [['start-callers', STARTER, 1]], found(STARTER => START)
    {
      'a fun' => "s() -> fun erx_domain:start_session/2.\n",
      'a quoted atom' => "s(P) -> 'erx_domain':'start_session'(P, \#{}).\n",
      'an apply' => "s(A) -> erlang:apply(erx_domain, start_session, A).\n",
      'a variable module' => "s(M, P) -> M:start_session(P, \#{}).\n",
      'a variable apply' => "s(M, A) -> apply(M, start_session, A).\n",
      'an import' => "-import(erx_domain, [info/1]).\n",
      'a macro' => "-define(DOMAIN, erx_domain).\n",
      'a function-like macro' => "-define(D(), erx_domain).\n",
      'the service' => "s(P, S) -> gen_server:call(erx_domain_srv, {start_session, P, S}, infinity).\n",
      'a call split across lines' => "s(P) ->\n    erx_domain:\n        start_session(P, \#{}).\n"
    }.each do |form, source|
      line = source.lines.index { |text| text.match?(/erx_domain|start_session/) } + 1
      assert_equal [['start-callers', OTHER, line]], found(OTHER => source), form
    end
    assert_equal [['start-callers', 'otp/lib/stdlib/src/seeded.erl', 1]], found('otp/lib/stdlib/src/seeded.erl' => START)
    assert_empty found('test/erlang/seeded_tests.erl' => START)
    assert_empty found('erlang/apps/erx_domain/src/erx_domain.erl' => "s(P, S) -> gen_server:call(erx_domain_srv, {start_session, P, S}).\n")
    assert_empty found(OTHER => "s() -> {start_session, 1}, erx_domain:info(x), \"erx_domain:start_session\".\n")
  end

  def test_only_the_starter_passes_a_display
    with_display = "s(P, D) -> erx_domain:start_session(P, \#{display => D}).\n"
    assert_empty found(KEEPER => with_display)
    assert_equal [['start-display', CONSOLE, 1]], found(CONSOLE => with_display)
    # A module outside the callers that starts a session fails start-callers, display or not.
    assert_equal [['start-callers', OTHER, 1]], found(OTHER => with_display)
    seeded = "s(P, D) ->\n    S = maps:put('default_display', D, \#{}),\n    erx_domain:start_session(P, S).\n"
    assert_equal [['start-display', CONSOLE, 2]], found(CONSOLE => seeded)
    via_service = "s(P, D) -> gen_server:call(erx_domain_srv, {start_session, P, \#{display => D}}).\n"
    assert_equal [['start-callers', OTHER, 1]], found(OTHER => via_service)
    assert_empty found(CONSOLE => "#{START}d() -> erlang:display(x), display(y), fun display/1.\n")
    assert_empty found(OTHER => "d(D) -> \#{display => D}.\n")
  end

  # The source check runs the rules over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    error = enforce_seeded(RULES, STARTER, "c(S) -> erx_domain:create(S).\n")
    assert_match "chokepoint starter-reach: #{STARTER}:1", error.message
  end
end
