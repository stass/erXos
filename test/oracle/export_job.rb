#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'oracle_export'

begin
  bytes = File.open('/inputs/job.json', File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
    raise Erx::Error, 'oracle export job is not a bounded regular file' unless input.stat.file? && input.size <= 1024 * 1024
    input.read(1024 * 1024 + 1) || ''.b
  end
  plan = Erx::JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'oracle export job')
  raise Erx::Error, 'oracle export job must be an object' unless plan.is_a?(Hash)
  inventory = Erx::OracleExport.call(source: '/native/erx-oracle', destination: '/artifacts',
                                    operation: plan.fetch('operation'), suite: plan['suite'],
                                    limits: plan.fetch('artifact_limits'))
  Erx::Terminal.puts("oracle artifacts: #{inventory.fetch('state')}; reporting evidence: #{inventory.fetch('mandatory_evidence')}")
rescue Erx::Error, SystemCallError, KeyError => error
  Erx::Terminal.puts(error.message)
  exit 1
end
