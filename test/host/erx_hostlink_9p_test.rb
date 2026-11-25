# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_hostlink_9p_tests.erl, the EUnit cases of the host link's 9P bridge
# (erx_hostlink_9p's core and erx_hostlink_files over a real erx_fs grant of
# erx_fs_test_tree, and erx_build's reading of the manifest's development flag),
# compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies) with the generated grammar from build/gen.
class ErxHostlink9pTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the suite exercises, compiled whole (ErlangBuild), and the
  # suite. The test tree declares
  # the erx_fs behaviour, which erx_files supplies.
  APPLICATIONS = %w[erx erx_files erx_uart].freeze
  TESTS = %w[test/erlang/erx_fs_test_tree.erl test/erlang/erx_hostlink_9p_tests.erl].freeze

  BRIDGE = 'erlang/apps/erx_uart/src/erx_hostlink_9p.erl'
  # A seeded bridge that passes a host's walk from NOFID through to the grant of a fid
  # the host attached, so the host would walk from that grant's root without naming a
  # fid it holds (docs/design-files.md, "Version and attach"):
  # a_hosts_walk_from_nofid_is_ebadf_test must catch it.
  GENERIC_ROUTE = "route(Request, Drawn, #bridge{fids = Fids} = B) ->\n"
  NOFID_THROUGH = "route({walk, ?ERX_P9_NOFID, _, _} = Request, _Drawn, #bridge{fids = Fids}) when map_size(Fids) > 0 ->\n" \
                  "    {ok, element(1, hd(maps:values(Fids))), Request};\n"

  def test_the_bridge_passes_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_bridge_that_passes_nofid_through_is_caught
    bridge = File.read(File.join(ROOT, BRIDGE))
    assert_equal 1, bridge.scan(GENERIC_ROUTE).size, 'erx_hostlink_9p has no generic route clause to seed before'
    output, status = eunit(BRIDGE => bridge.sub(GENERIC_ROUTE, NOFID_THROUGH + GENERIC_ROUTE))
    refute status.success?, output
    assert_match(/a_hosts_walk_from_nofid_is_ebadf_test\.\.\.\*failed\*/, output)
  end

  private

  def eunit(seeded = {})
    Dir.mktmpdir('erx-hostlink-9p-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: seeded)
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_hostlink_9p_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
