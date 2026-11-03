# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/chokepoint_rules'

# What every chokepoint test shares: the machinery's and the cross-cutting
# rules' cases are in chokepoints_test.rb, and each group's own cases in
# chokepoints_GROUP_test.rb.
module ChokepointsHelper
  Rules = Erx::ChokepointRules
  Chokepoints = Erx::Chokepoints
  ROOT = File.expand_path('../..', __dir__)

  def evaluate(rules, files, imported: [])
    Chokepoints.violations(rules, names: files.keys.sort, imported: ->(path) { imported.include?(path) },
                                  read: ->(path) { files.fetch(path) })
  end

  def rule(name) = Rules::ALL.find { |candidate| candidate.name == name } || flunk("no rule #{name}")
end
