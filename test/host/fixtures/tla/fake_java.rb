#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

def emit(code, body, level: 0)
  puts "@!@!@STARTMSG #{code}:#{level} @!@!@"
  puts body
  puts "@!@!@ENDMSG #{code} @!@!@"
end

if ARGV == ['-version']
  puts 'openjdk fixture'
  exit 0
end

if ARGV.include?('pcal.trans')
  abort 'translation has no heap limit' unless ARGV.any? { |argument| argument.start_with?('-Xmx') }
  exit 0
end

config = ARGV.fetch(ARGV.index('-config') + 1)
if config == 'Slow.cfg'
  trap('TERM') {}
  File.write(ENV.fetch('ERX_TLA_FIXTURE_READY'), Process.pid.to_s)
  sleep 0.8
  File.write(ENV.fetch('ERX_TLA_FIXTURE_SURVIVOR'), 'survived')
end

emit(2262, 'TLC2 Version fixture')
emit(2219, 'SANY finished.')
emit(2185, 'Starting...')
emit(2193, 'Model checking completed. No error has been found.')
emit(2199, '4 states generated, 3 distinct states found, 0 states left on queue.')
emit(2186, 'Finished in 20ms at a tool-reported timestamp')
