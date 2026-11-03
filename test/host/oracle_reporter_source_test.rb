# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'json'

class OracleReporterSourceTest < Minitest::Test
  def test_reporting_copy_only_adds_observations_to_pinned_controller
    directory = File.expand_path('../oracle/common_test', __dir__)
    record = JSON.parse(File.read(File.join(directory, '../reporter-source.json')))
    modified = File.binread(File.join(directory, 'test_server_ctrl.erl'))
    assert_equal record.fetch('reporting_sha256'), Digest::SHA256.hexdigest(modified)
    original = modified.sub(/\n%% erXos reporting support begin\.\n.*?%% erXos reporting support end\.\n/m, '')
    observers = original.lines.select { |line| line.match?(/\A\s*_ = catch erx_oracle_observer:/) }
    calls = original.lines.select { |line| line.match?(/\A\s*\{(?:ErxJob, ErxReporting|_, ErxReporting|_, ErxSpawned)\} = erx_report/) }
    assert_equal 6, observers.size
    assert_equal 8, calls.size
    original = original.lines.reject do |line|
      observers.include?(line) || calls.include?(line) || line == "    Observation = make_ref(),\n" ||
        line.start_with?('%% Modified by erXos:', '%% Copyright (c) 2026, Stanislav Sedov')
    end.join
    original = original.gsub('State#state{erx_reporting=ErxReporting}', 'State')
                       .gsub(',erx_reporting=ErxReporting', '').gsub(',erx_reporting=ErxSpawned', '')
                       .gsub(', erx_reporting=undefined', '').gsub(', ErxJob', '')
    assert_equal record.fetch('original_sha256'), Digest::SHA256.hexdigest(original)
  end
end
