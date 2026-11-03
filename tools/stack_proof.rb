#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs the stack proof over the C17 cores at -O0 and -O2 with the clang
# ERX_CLANG names and its LLVM binary tools, and writes the report to
# OUTPUT/report.txt (tools/lib/erx/stack_proof_run.rb).

require 'optparse'
require_relative 'lib/erx/runner'
require_relative 'lib/erx/stack_proof_run'

root = File.expand_path('..', __dir__)
options = { output: File.join(root, 'build/stack-proof') }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/stack_proof.rb [--output DIRECTORY]'
  flags.on('--output DIRECTORY') { |path| options[:output] = File.expand_path(path) }
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
end
begin
  compiler = ENV.fetch('ERX_CLANG', '')
  raise Erx::Error, 'set ERX_CLANG to the installed LLVM 23.1.3 clang; see README.md' if compiler.empty?

  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
  report = Erx::StackProofRun.call(root: root, compiler: compiler, runner: runner, output: options.fetch(:output))
  report.grep(/\AC17 cores: /).each { |line| Erx::Terminal.puts(line) }
rescue Erx::Error, SystemCallError => error
  Erx::Terminal.puts(error.message)
  exit 1
end
