#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'optparse'
require_relative 'lib/erx/terminal_generation'

options = { root: File.expand_path('..', __dir__), output: nil, check: false }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/gen_terminal.rb [--check] [--root PATH] [--output PATH]'
  flags.on('--root PATH') { |path| options[:root] = File.expand_path(path) }
  flags.on('--output PATH') { |path| options[:output] = File.expand_path(path) }
  flags.on('--check') { options[:check] = true }
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
  plan = Erx::TerminalRules.plan(root: options.fetch(:root))
  output = options.fetch(:output) || options.fetch(:root)
  FileUtils.mkdir_p(output) unless options.fetch(:check)
  if options.fetch(:check)
    Erx::TerminalRules.check(plan, root: output)
  else
    Erx::TerminalRules.publish(plan, root: output)
  end
  puts "Terminal: #{plan.size} artifacts #{options.fetch(:check) ? 'match' : 'published'}"
rescue OptionParser::ParseError, Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
end
