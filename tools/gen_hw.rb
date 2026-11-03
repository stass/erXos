#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/erx/hardware'

options = { root: File.expand_path('..', __dir__), check: false }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/gen_hw.rb [--check] [--root PATH]'
  flags.on('--root PATH') { |path| options[:root] = File.expand_path(path) }
  flags.on('--check') { options[:check] = true }
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
  plan = Erx::Hardware.output_plan(root: options.fetch(:root))
  if options.fetch(:check)
    Erx::Hardware.check_outputs(plan, root: options.fetch(:root))
  else
    Erx::Hardware.publish_outputs(plan, root: options.fetch(:root))
  end
  puts "Hardware: #{plan.size} artifacts #{options.fetch(:check) ? 'match' : 'published'}"
rescue OptionParser::ParseError, Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
end
