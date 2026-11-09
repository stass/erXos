# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/memdraw_build'

# erx_memdraw (display/memdraw) against its oracles (docs/design-display.md,
# "The pixel primitives"). The NIF, built for the host with UBSan in trap mode,
# runs in stock OTP 29.1.2's emulator under test/erlang/erx_memdraw_tests.erl:
# random draw messages through erx_draw_core and erx_memdraw agree pixel for
# pixel with erx_draw_ref, and Y payloads decode alike through erx_draw_image
# and 9front's cloadmemimage. The emulator cannot load ASan's runtime into a
# NIF (TODO.md, storage), so the same operations, rectangles far outside every
# image among them, also run in a harness under ASan and UBSan. Each check is
# shown to fail on the fault it guards.
class ErxMemdrawTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  HARNESS = 'test/display/erx_memdraw_stress.c'
  MODULES = Erx::MemdrawBuild::MODULES
  Seed = Erx::MemdrawBuild::Seed

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-memdraw-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_draws_agree_with_erx_draw_ref
    prepare
    assert_equal 'diff ok', run_cases('diff', 400)
  end

  def test_y_decodes_alike_through_cloadmemimage
    prepare
    assert_equal 'y ok', run_cases('y', 4000)
  end

  def test_unit_cases
    prepare
    assert_equal 'unit ok', run_cases('unit', 1)
  end

  def test_far_rectangles_stay_inside_images_under_asan
    output, status = stress
    assert status.success?, output
    assert_match(/^stress ok$/, output)
  end

  def test_seeded_operator_change_fails_the_comparison
    prepare(seed: Seed.new(path: 'display/libmemdraw/draw.c', from: "alphacalc11,\t\t/* SoverD */",
                           to: "alphacalc0,\t\t/* SoverD */"))
    assert_match(/\Adiff FAIL/, run_cases('diff', 400))
  end

  def test_seeded_clip_bypass_is_caught_by_asan
    output, status = stress(seed: Seed.new(path: 'display/memdraw/erx_draw_clip.c',
                                           from: 'if (!clip_to(&r, widen(dst->r)) || !clip_to(&r, widen(dclipr)))',
                                           to: 'if (!clip_to(&r, widen(dclipr)))'))
    refute status.success?
    assert_match(/AddressSanitizer|runtime error|SEGV|Assertion failed/, output)
  end

  def test_seeded_run_length_fault_fails_the_y_comparison
    prepare
    seeded = File.read(File.join(ROOT, MODULES.first)).sub('Count = C - 127,', 'Count = C - 128,')
    File.write(File.join(@directory, 'erx_draw_image.erl'), seeded)
    erlc(File.join(@directory, 'erx_draw_image.erl'))
    assert_match(/\Ay FAIL/, run_cases('y', 4000))
  end

  private

  def prepare(seed: nil)
    Erx::MemdrawBuild.erlang_cases(root: ROOT, otp: OTP, directory: @directory, compiler: COMPILER, seed: seed)
  end

  def erlc(*sources) = Erx::MemdrawBuild.erlc(otp: OTP, directory: @directory, sources: sources)

  def run_cases(mode, rounds, seed: 1)
    Erx::MemdrawBuild.run_cases(otp: OTP, directory: @directory, mode: mode, rounds: rounds, seed: seed)
  end

  def stress(seed: nil)
    program = Erx::MemdrawBuild.program(root: ROOT, harness: HARNESS, directory: @directory, compiler: COMPILER,
                                        seed: seed)
    Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0:abort_on_error=0' }, 'gtimeout', '-k', '10', '300',
                    program, '1', '3000', stdin_data: '')
  end
end
