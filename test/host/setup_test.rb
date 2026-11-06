# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative '../../tools/lib/erx/setup'

class SetupTest < Minitest::Test
  NAMES = Erx::Setup::ALL_STEPS.map(&:name).freeze

  def everything(value) = NAMES.to_h { |name| [name, value] }

  def test_fresh_tree_runs_every_step_in_order
    assert_equal NAMES, Erx::Setup.plan({}).map(&:name)
    assert_equal NAMES.first(3), %w[source-otp source-musl source-arm-registers]
    assert_equal %w[oracle-jit oracle-emu runtime], NAMES.last(3)
  end

  def test_complete_tree_runs_nothing
    assert_empty Erx::Setup.plan(everything(true))
  end

  def test_only_missing_steps_run
    present = everything(true).merge('source-musl' => false, 'runtime' => false)
    assert_equal %w[source-musl runtime], Erx::Setup.plan(present).map(&:name)
  end

  def test_tla_tools_is_not_a_step
    refute(NAMES.any? { |name| name.include?('tla') })
  end

  def test_archive_directory_is_the_sibling_downloads_of_the_cache
    assert_equal '/x/build/downloads', Erx::Setup.archive_directory('/x/build/third_party')
  end

  def test_adopt_refuses_bytes_that_do_not_match_the_pin
    Dir.mktmpdir('erx-setup-') do |root|
      FileUtils.copy_file(File.expand_path('../../deps.lock', __dir__), File.join(root, 'deps.lock'))
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
      dependencies = Erx::Dependencies.new(root: root, runner: runner)
      bogus = File.join(root, 'bogus.tar.gz')
      File.binwrite(bogus, 'not the pinned bytes')
      assert_raises(Erx::Error) { dependencies.adopt('musl', from: bogus) }
      assert_empty Dir.glob(File.join(root, 'build/downloads/*.tar.gz'))
    end
  end
end
