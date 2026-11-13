# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the virtio-gpu driver's parse of what the device wrote,
# erx_virtio_gpu_core:decode/2, and of its flush plan, compiled from source and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It
# runs the module as it is, then each seeded copy, which must fail with its marker: one
# that takes a fenced answer to an unfenced request (the reference holds the fence), and one
# that clips a rectangle a pixel past the screen's right edge (the plan's check holds every
# transfer inside the image).
module ErxVirtioGpuCoreFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_display/src/erx_virtio_gpu_core.erl')
  FUZZ_SOURCE = File.join(ROOT, 'test/erlang/erx_virtio_gpu_core_fuzz.erl')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Seed = Data.define(:fault, :anchor, :replacement, :marker)
  SEEDS = [
    Seed.new(fault: 'a fenced answer taken for an unfenced request',
             anchor: 'fence_check(none, Flags, _FenceId, Result) when Flags band ?ERX_VIRTIO_GPU_FLAG_FENCE =:= 0 -> Result;',
             replacement: 'fence_check(none, _Flags, _FenceId, Result) -> Result;',
             marker: 'disagrees_with_reference'),
    Seed.new(fault: "a rectangle clipped a pixel past the screen's right edge",
             anchor: 'min(X1, Width)', replacement: 'min(X1, Width + 1)', marker: 'plan_wrong')
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |planted|
      raise "seed anchor for #{planted.fault} is not unique" unless source.scan(planted.anchor).size == 1

      output, status = fuzz(source.sub(planted.anchor) { planted.replacement }, seed: seed)
      abort("#{planted.fault} passed:\n#{output}") if status.success? || !output.include?(planted.marker)
    end
    puts 'erx_virtio_gpu_core agrees with its reference and its plan check, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-virtio-gpu-core-fuzz') do |work|
      module_path = File.join(work, 'erx_virtio_gpu_core.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, FUZZ_SOURCE,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_virtio_gpu_core_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxVirtioGpuCoreFuzz.run(seed: options.fetch(:seed))
end
