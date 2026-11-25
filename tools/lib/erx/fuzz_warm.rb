# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'runner'

module Erx
  # The compile step of the Erlang fuzz targets. A target calls
  # erx_fuzz_warm:closure(?MODULE) before its first round, so the module that
  # defines it must be compiled beside the target: a driver calls compile,
  # which adds it, and never runs erlc itself.
  module FuzzWarm
    SOURCE = File.expand_path('../../../test/erlang/erx_fuzz_warm.erl', __dir__)
    private_constant :SOURCE
    COMPILE_SECONDS = 120
    LOG_BYTES = 64 * 1024

    module_function

    # Compiles sources (paths) and the warm-up module into work, with each include
    # directory (a path or an array of paths) on erlc's include path, under
    # COMPILE_SECONDS. A failed or timed-out compile raises Erx::Error with the first
    # LOG_BYTES of erlc's output, read before the caller's work directory goes.
    def compile(work:, sources:, include: [])
      logs = File.join(work, 'logs')
      runner = Runner.new(owner_root: work, log_dir: logs)
      argv = [ENV.fetch('ERX_ERLC'), *Array(include).flat_map { |directory| ['-I', directory] },
              '-o', work, *sources, SOURCE]
      runner.run(argv, name: 'erlc', deadline: COMPILE_SECONDS, chdir: work)
    rescue CommandError => error
      raise Error, "erlc #{error.result.fetch('state')}:\n#{File.read(error.result.fetch('log'), LOG_BYTES)}"
    end
  end
end
