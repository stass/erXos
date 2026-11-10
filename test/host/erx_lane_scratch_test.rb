# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The lane driver's scratch growth (erx_lane_scratch_grow in
# otp/erts/emulator/sys/erxos/erx_lane_core.c) through test/fixtures/erx_lane_scratch_driver.c,
# which grows a scratch with an allocator that works or fails. A growth that cannot be
# allocated, or whose size overflows, must say so and leave the scratch as it was, since the driver then ends the
# connection as erx_lane_no_memory: the receiver's shortage is not the peer's fault, and the
# frame is never judged against a scratch too small for it.
class ErxLaneScratchTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  BIGGER = 4 << 20 # more than ERX_FUNNEL_CTL_SCRATCH, the scratch's start
  OVERFLOW = (1 << 64) - 1 # SIZE_MAX, what erx_funnel_check_scratch_bytes returns on overflow
  Outcome = Data.define(:start, :result, :len, :allocs, :releases, :same_block)

  def test_a_frame_that_needs_more_grows_the_scratch_by_a_fresh_block
    outcome = grow(want: BIGGER, fail: false)
    assert_equal 1, outcome.result
    assert_equal BIGGER, outcome.len
    assert_equal 1, outcome.allocs
    assert_equal 1, outcome.releases
    assert_equal 0, outcome.same_block
  end

  def test_a_frame_the_scratch_holds_allocates_nothing
    outcome = grow(want: 16, fail: true)
    assert_equal 1, outcome.result
    assert_equal 0, outcome.allocs
    assert_equal outcome.start, outcome.len
    assert_equal 0, outcome.releases
    assert_equal 1, outcome.same_block
  end

  def test_a_growth_that_cannot_be_allocated_fails_and_leaves_the_scratch
    outcome = grow(want: BIGGER, fail: true)
    assert_equal 0, outcome.result
    assert_equal 1, outcome.allocs
    assert_equal outcome.start, outcome.len
    assert_equal 0, outcome.releases
    assert_equal 1, outcome.same_block
  end

  def test_an_overflowing_size_fails_without_asking_the_allocator
    outcome = grow(want: OVERFLOW, fail: false)
    assert_equal 0, outcome.result
    assert_equal 0, outcome.allocs
    assert_equal outcome.start, outcome.len
    assert_equal 0, outcome.releases
    assert_equal 1, outcome.same_block
  end

  private

  def grow(want:, fail:)
    output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary,
                                     want.to_s, fail ? '1' : '0', stdin_data: '')
    assert status.success?, output
    Outcome.new(*output.split.map(&:to_i))
  end

  def binary
    @directory ||= Dir.mktmpdir('erx-lane-scratch-')
    path = File.join(@directory, 'driver')
    output, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT),
                                     '-I', File.join(ROOT, 'include'),
                                     '-I', File.join(ROOT, 'otp/erts/emulator/sys/erxos'),
                                     File.join(ROOT, 'test/fixtures/erx_lane_scratch_driver.c'),
                                     File.join(ROOT, 'otp/erts/emulator/sys/erxos/erx_lane_core.c'),
                                     '-o', path, stdin_data: '')
    assert status.success?, output
    path
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && passed? && File.directory?(@directory)
  end
end
