# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/sysreg'

# hw/sysreg/aarch64.json against Arm's pinned archive, which only this test
# and tools/erx sysreg refresh read. `make check` excuses it
# (STANDALONE_INTEGRATION_TESTS in tools/erx), so no gate depends on what is
# fetched into build/; it skips with how to fetch when the archive is absent.
class SysregRefreshIntegrationTest < Minitest::Test
  REPOSITORY = File.expand_path('../..', __dir__)

  def test_checked_in_specification_matches_the_pinned_arm_source
    unless File.file?(File.join(REPOSITORY, Erx::Sysreg::SOURCE))
      skip "Arm's archive is not fetched; run tools/erx fetch --source arm-registers to verify #{Erx::Sysreg::SPECIFICATION}"
    end
    assert Erx::Sysreg.verify(root: REPOSITORY)
  end
end
