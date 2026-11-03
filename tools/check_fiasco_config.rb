#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Checks the stopgap kernel's resolved configuration (globalconfig.out) against
# the fork's rules (tools/lib/erx/fiasco_config.rb). `tools/erx build fiasco`
# runs the same check after every configuration step; this script checks a
# file by hand, the build's own one by default.

require 'optparse'
require_relative 'lib/erx/runner'
require_relative 'lib/erx/fiasco_config'

root = File.expand_path('..', __dir__)
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/check_fiasco_config.rb [RESOLVED_CONFIG]'
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::NeedlessArgument, ARGV.drop(1).join(' ') if ARGV.size > 1
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
end
path = ARGV.first || File.join(root, 'build/fiasco/kernel/globalconfig.out')
begin
  Erx::FiascoConfig.check(path)
  Erx::Terminal.puts("#{path}: the stopgap kernel configuration follows the fork's rules")
rescue Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
end
