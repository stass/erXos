# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_hostlink_tests.erl, the EUnit cases of erx_hostlink's pure parts and
# its install and web facets, compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies). erx_device_record and erx_pl011 are not loaded: no
# case starts the host link's process, which the production image's boot runs end to end.
class ErxHostlinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated header erx_abi.hrl named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = %w[erlang/apps/erx/src/erx_build.erl
               erlang/apps/erx/src/erx.erl test/erlang/stand_in/erx_dist.erl
               erlang/apps/erx_hostlink/src/erx_hostlink.erl erlang/apps/erx_hostlink/src/erx_hostlink_install.erl
               erlang/apps/erx_hostlink/src/erx_hostlink_web.erl erlang/apps/erx_hostlink/src/erx_hostlink_files.erl
               erlang/apps/erx_hostlink/src/erx_hostlink_frame.erl erlang/apps/erx_hostlink/src/erx_hostlink_stream.erl
               erlang/apps/erx_hostlink/src/erx_hostlink_payload.erl erlang/apps/erx_hostlink/src/erx_hostlink_session.erl
               test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_hostlink_tests.erl].freeze

  def test_the_host_links_pure_parts_pass_under_eunit
    Dir.mktmpdir('erx-hostlink-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_hostlink_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
