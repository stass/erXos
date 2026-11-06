# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_device_record_tests.erl, the EUnit cases of the device record parse,
# against erx_device_record compiled from source on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). The module calls nothing of erx_device, so it needs no hosted build.
class ErxDeviceRecordTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_device_record_cases_pass_under_eunit
    Dir.mktmpdir('erx-device-record-test') do |work|
      sources = [File.join(ROOT, 'erlang/apps/erx/src/erx_device_record.erl'), File.join(ROOT, 'test/erlang/erx_device_record_tests.erl')]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *sources, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_device_record_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
