#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'oracle_guest'

RESULT_DIRECTORY = '/tmp/erx-oracle'
RESULT_PATH = "#{RESULT_DIRECTORY}/result.json"

# ContainerOracleJob creates the private directory itself and refuses one
# that exists. A job that fails before it runs (an unreadable job file, a
# json that cannot be used) has no directory yet, and its diagnostic is the
# only result the host can read, so the directory is created here with mode 0700.
def write_result(result)
  Dir.mkdir(RESULT_DIRECTORY, 0o700) unless File.directory?(RESULT_DIRECTORY)
  File.write(RESULT_PATH, JSON.pretty_generate(result) + "\n")
end

begin
  bytes = File.binread('/inputs/job.json', 1024 * 1024 + 1)
  plan = Erx::JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'oracle job')
  result = Erx::ContainerOracleJob.new(plan).call
  write_result(result)
  exit(result.fetch('state') == 'completed' ? 0 : 1)
rescue Erx::Error, SystemCallError, KeyError => error
  Erx::Terminal.puts(error.message)
  write_result('state' => 'setup_error', 'diagnostic' => error.message)
  exit 1
end
