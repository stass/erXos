# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# AT6's chokepoint (docs/design-app-trees.md, "Invariants"): among the modules of
# erlang/apps only erx_svc_client names /svc.
class SvcChokepointsTest < Minitest::Test
  include ChokepointsHelper

  REBOOT = 'erlang/apps/erx_shell/src/erx_cmd_reboot.erl'
  STARTER = 'erlang/apps/erx_starter/src/erx_starter.erl'
  CLIENT = 'erlang/apps/erx/src/erx_svc_client.erl'
  DESK = 'erlang/apps/erx_desk/src/erx_desk_cmd_clock.erl'

  def found(files) = erlang_found(['svc-paths'], files)

  def test_the_tree_passes
    assert_empty evaluate([rule('svc-paths')], erlang_tree).map(&:to_s)
  end

  def test_a_command_naming_svc_fails_the_build
    enforce_seeded(['svc-paths'], REBOOT, "w(L) -> file:write_file(<<\"/svc/machine/ctl\">>, L).\n")
  end

  def test_every_spelling_of_a_path_under_svc_is_refused
    {
      'a binary path' => "w(L) -> file:write_file(<<\"/svc/machine/ctl\">>, L).\n",
      'the directory' => "l() -> file:list_dir(\"/svc\").\n",
      'a sigil' => "p(N) -> <<~\"/svc/\", N/binary>>.\n",
      'a joined component' => "p(N) -> filename:join([\"/\", \"svc\", N]).\n",
      'a binary component' => "p(N) -> filename:join([<<\"/\">>, <<\"svc\">>, N]).\n",
      'a relative join' => "p(N) -> filename:join(\"/\", \"svc/\" ++ N).\n",
      'a macro' => "-define(SVC, \"/svc/\").\n",
      'a quoted atom' => "r() -> file:read_file('/svc/machine/status').\n",
      'a doc string not at a line start' => "x() -> ok. -doc \"/svc\".\n"
    }.each do |form, source|
      assert_equal [['svc-paths', STARTER, 1]], found(STARTER => source), form
    end
  end

  def test_the_client_prose_and_other_names_pass
    assert_empty found(CLIENT => "tree(Name) -> <<\"/svc/\", Name/binary>>.\n")
    allowed = <<~'ERL'
      -moduledoc """
      Writes /svc/machine/ctl through erx_svc_client:command/3.
      """.
      -doc "Reads /svc/NAME/status.".
      -doc("Opens \"/svc\" entries.").
      %% /svc in a comment is not code.
      r(N) -> erx_svc_client:read(N, <<"status">>, 64, 5000).
      s() -> {svc, <<"svcs">>, "/svcs", "/var/svc", erx_svc, 'svc'}.
    ERL
    assert_empty found(REBOOT => allowed)
    # A command outside the command shell's application is read too.
    assert_equal [['svc-paths', DESK, 1]], found(DESK => "r() -> file:read_file(\"/svc/clock/status\").\n")
  end
end
