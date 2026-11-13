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

  # The violations of the named Erlang rules over files held in memory, as
  # [rule, path, line].
  def erlang_found(names, files)
    evaluate(names.map { |name| rule(name) }, files).map { |violation| [violation.rule, violation.path, violation.line] }
  end

  # The tree's Erlang sources, path => bytes.
  def erlang_tree
    Erx::ErlangText::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
                          .to_h { |path| [path, File.binread(File.join(ROOT, path))] }
  end

  # The error the source check raises over one seeded file in a scratch
  # tree, read as git lists it beside a missing README.md, as imported
  # code when it lies under otp/.
  def enforce_seeded(names, path, text)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(path)))
      File.write(File.join(root, path), text)
      assert_raises(Erx::Error) do
        Chokepoints.enforce(names.map { |name| rule(name) }, root: root, names: [path, 'README.md'],
                                                             imported: ->(name) { name.start_with?('otp/') })
      end
    end
end
end
