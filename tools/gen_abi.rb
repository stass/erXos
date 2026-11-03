#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/erx/abi'

options = { root: File.expand_path('..', __dir__), architecture: 'aarch64', check: false }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/gen_abi.rb [--check] [--root PATH]'
  flags.on('--root PATH', 'Read and publish beneath this repository') { |path| options[:root] = File.expand_path(path) }
  flags.on('--architecture NAME', 'Select the architecture declaration file') { |name| options[:architecture] = name }
  flags.on('--check', 'Compare generated paths and bytes without publishing') { options[:check] = true }
  flags.on('--help', 'Show this help') { puts flags; exit 0 }
end

begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
  plan = Erx::ABI::Generator.plan(root: options.fetch(:root), architecture: options.fetch(:architecture))
  if options.fetch(:check)
    Erx::ABI::Generator.check(plan, root: options.fetch(:root))
    Erx::Terminal.puts("ABI: #{plan.files.size} generated artifacts match")
  else
    Erx::ABI::Generator.publish(plan, root: options.fetch(:root))
    Erx::Terminal.puts("ABI: published #{plan.files.size} generated artifacts")
  end
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
rescue Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
end
