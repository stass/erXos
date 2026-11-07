#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Writes the Terminal generator's files alone into a directory, to read them
# outside a build. The build generates every generator's files into
# build/gen itself (tools/erx generate, Erx::Generated.ensure).

require 'optparse'
require_relative 'lib/erx/generated'
require_relative 'lib/erx/runner'

options = { root: File.expand_path('..', __dir__), output: nil }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/gen_terminal.rb --output PATH [--root PATH]'
  flags.on('--root PATH', 'Read beneath this repository') { |path| options[:root] = path }
  flags.on('--output PATH', 'Write into this directory, empty or an earlier output of this script') do |path|
    options[:output] = path
  end
  flags.on('--help', 'Show this help') { puts flags; exit 0 }
end

begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
  raise OptionParser::MissingArgument, '--output' unless options.fetch(:output)

  result = Erx::Generated.generate_one('terminal', root: options.fetch(:root), output: options.fetch(:output))
  Erx::Terminal.puts("Terminal: generated files in #{result.output}")
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
rescue Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
end
