# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/fiasco_origins'

class FiascoOriginsTest < Minitest::Test
  def test_explicit_fiasco_gpl2_prose_precedes_package_default
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'source.cpp'), <<~SOURCE)
        /*
         * This file is distributed under the terms of the GNU General Public
         * License, version 2. Please see the COPYING-GPL-2 file for details.
         */
      SOURCE
      rules = Erx::FiascoOrigins.explicit_grant_rules(directory)
      assert_equal 'GPL-2.0-only', rules.find { |rule| rule.fetch('pattern') == 'source.cpp' }&.fetch('license')
    end
  end
end
