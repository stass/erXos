# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/memdraw_build'

# The fuzz target of Y's decoding (docs/design-display.md, "Draw messages"):
# random and mutated image(6) payloads through erx_draw_image:decode/3 and
# through 9front's cloadmemimage in the host build of erx_memdraw, which
# must agree on the pixels, the bytes taken and every refusal. It runs the
# `y` mode of test/erlang/erx_memdraw_tests.erl for more rounds than the
# landing test, test/host/erx_memdraw_test.rb.
module ErxMemdrawYFuzz
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  ROUNDS = 200_000

  module_function

  def run(seed:)
    abort('stock OTP not built: make oracle-bootstrap') unless File.directory?(OTP)
    Dir.mktmpdir('erx-memdraw-fuzz-') do |directory|
      Erx::MemdrawBuild.erlang_cases(root: ROOT, otp: OTP, directory: directory,
                                     compiler: ENV.fetch('ERX_CLANG', 'clang'))
      verdict = Erx::MemdrawBuild.run_cases(otp: OTP, directory: directory, mode: 'y', rounds: ROUNDS, seed: seed)
      abort(verdict) unless verdict == 'y ok'
    end
    puts "fuzz: #{ROUNDS} rounds ok"
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMemdrawYFuzz.run(seed: seed)
end
