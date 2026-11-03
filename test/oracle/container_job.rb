#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'oracle_guest'

begin
  bytes = File.binread('/inputs/job.json', 1024 * 1024 + 1)
  plan = Erx::JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'oracle job')
  result = Erx::ContainerOracleJob.new(plan).call
  File.write('/tmp/erx-oracle/result.json', JSON.pretty_generate(result) + "\n")
  exit(result.fetch('state') == 'completed' ? 0 : 1)
rescue Erx::Error, SystemCallError, KeyError => error
  File.write('/tmp/erx-oracle/result.json', JSON.pretty_generate('state' => 'setup_error', 'diagnostic' => error.message) + "\n")
  Erx::Terminal.puts(error.message)
  exit 1
end
