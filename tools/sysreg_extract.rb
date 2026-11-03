#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/erx/sysreg'

root = File.expand_path('..', __dir__)
check = false
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/sysreg_extract.rb [--check] [--root PATH]'
  flags.on('--root PATH') { |path| root = File.expand_path(path) }
  flags.on('--check') { check = true }
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
  root = File.realpath(root)
  plan = Erx::Sysreg.plan(root: root)
  bytes = plan.fetch('hw/sysreg/aarch64.json')
  output = File.join(root, 'hw/sysreg/aarch64.json')
  if check
    Erx::Sysreg.check_outputs(plan, root: root)
  else
    temporary = output + ".#{Process.pid}.tmp"
    created = false
    begin
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        created = true
        file.write(bytes)
      end
      File.rename(temporary, output)
    ensure
      File.unlink(temporary) if created && File.file?(temporary) && !File.symlink?(temporary)
    end
  end
  puts "System registers: #{check ? 'match pinned extraction' : 'published'}"
rescue OptionParser::ParseError, Erx::Error, SystemCallError => error
  Erx::Terminal.puts(error.message)
  exit 1
end
