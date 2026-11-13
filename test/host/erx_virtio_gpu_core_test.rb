# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_virtio_gpu_core_tests.erl, the cases of the virtio-gpu driver's pure
# core, against erx_virtio_gpu_core compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies). Then each seeded fault, applied to a copy of the
# module, must fail the case named for it: a channel conversion that swaps red and blue, a
# frame whose last request carries no fence, a transfer offset off by the pixel size, a
# parse that takes any fence_id as the request's, and a frame done before every request is
# answered, which would let flush/3 return while the device still reads the image.
class ErxVirtioGpuCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding the module (compiled whole, ErlangBuild), the module and the cases.
  APPLICATIONS = %w[erx_display erx_fb].freeze
  MODULE = 'erlang/apps/erx_fb/src/erx_virtio_gpu_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_virtio_gpu_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'x8r8g8b8 shown as R8G8B8X8, red and blue swapped',
             anchor: 'format(<<"x8r8g8b8">>) -> {ok, ?ERX_VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM};',
             replacement: 'format(<<"x8r8g8b8">>) -> {ok, 134};',
             catching_case: 'x8r8g8b8_is_blue_first_test'),
    Seed.new(fault: "the frame's last request without its fence",
             anchor: 'fence_at(Last, Last, FenceId) -> {fence, FenceId};',
             replacement: 'fence_at(Last, Last, _FenceId) -> none;',
             catching_case: 'flush_of_one_rectangle_test'),
    Seed.new(fault: "a transfer's offset that forgets the pixel's 4 bytes",
             anchor: 'Offset = Y * Stride + X * ?BYTES_PER_PIXEL,',
             replacement: 'Offset = Y * Stride + X,',
             catching_case: 'flush_of_one_rectangle_test'),
    Seed.new(fault: "any fence_id taken as a fenced request's",
             anchor: 'fence_check({fence, FenceId}, Flags, FenceId, Result) when',
             replacement: 'fence_check({fence, _Want}, Flags, _FenceId, Result) when',
             catching_case: 'decode_holds_the_fence_to_the_request_test'),
    Seed.new(fault: 'a frame done while a request is still in flight',
             anchor: 'case map_size(Inflight) of',
             replacement: 'case 0 of',
             catching_case: 'frame_posts_waits_and_finishes_test')
  ].freeze

  def test_virtio_gpu_core_cases_pass_under_eunit
    output, status = run_cases(File.binread(MODULE_SOURCE))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(source.sub(seed.anchor) { seed.replacement })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}.*\*failed\*/m, output, seed.fault)
    end
  end

  private

  # The module's text compiled in place of the application's own, then the cases.
  def run_cases(module_text)
    Dir.mktmpdir('erx-virtio-gpu-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_virtio_gpu_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
