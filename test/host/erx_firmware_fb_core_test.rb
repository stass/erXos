# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_firmware_fb_core_tests.erl on stock OTP: the firmware framebuffer
# driver's pure core (erlang/apps/erx_fb/src/erx_firmware_fb_core.erl), with erx_chan, the
# channel parser it calls. The copy it plans is test/host/fb_store_test.rb's.
class ErxFirmwareFbCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  MODULES = %w[erlang/apps/erx_memdraw/src/erx_chan.erl erlang/apps/erx_fb/src/erx_firmware_fb_core.erl
               test/erlang/erx_firmware_fb_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-firmware-fb-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_core_cases
    text, status = Open3.capture2e(File.join(OTP, 'bin/erlc'), '-o', @directory, *MODULES.map { |path| File.join(ROOT, path) },
                                   stdin_data: '')
    assert status.success?, text
    text, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, File.join(OTP, 'bin/erl'), '-noshell',
                                   '-pa', @directory, '-eval',
                                   'case eunit:test(erx_firmware_fb_core_tests) of ok -> halt(0); _ -> halt(1) end.',
                                   stdin_data: '')
    assert status.success?, text
  end
end
