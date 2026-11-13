# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz targets of the SD host controller's pure cores, one per parser of what the card
# or the controller writes and one per state machine (test/erlang/erx_blk_sd_fuzz.erl),
# compiled from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), so they need no hosted build. They run the modules as they are, then a copy
# of erx_blk_sd_card without READ_BL_LEN's upper bound, which must fail: the CSD target then
# finds an admitted card whose last byte address does not fit 32 bits. The SD table of
# erx_blk_write is fuzzed with them, against its reference list.
module ErxBlkSdFuzz
  ROOT = File.expand_path('../..', __dir__)
  CARD = File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_sd_card.erl')
  HOST = File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_sd_host.erl')
  FUZZ = File.join(ROOT, 'test/erlang/erx_blk_sd_fuzz.erl')
  # The write path's SD table and the request range it uses.
  WRITE = File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_write.erl')
  REQUEST = File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_request.erl')
  # erx_blk_sd_host includes the generated erx_hw_sdhci.hrl, in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  BOUNDED = 'when Len >= 9, Len =< 11 ->'
  UNBOUNDED = 'when Len >= 9 ->'
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    card = File.binread(CARD)
    raise "no READ_BL_LEN bound in #{CARD}" unless card.include?(BOUNDED)

    output, status = fuzz(card, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ targets$/)
    puts output
    output, status = fuzz(card.sub(BOUNDED, UNBOUNDED), seed: seed)
    abort("admitting READ_BL_LEN above 11 passed:\n#{output}") if status.success? ||
                                                           !output.include?('last_address_overflow')
    puts 'erx_blk_sd parsers agree with their references, and admitting READ_BL_LEN above 11 does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(card_text, seed:)
    Dir.mktmpdir('erx-blk-sd-fuzz') do |work|
      card_path = File.join(work, 'erx_blk_sd_card.erl')
      File.binwrite(card_path, card_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, card_path, HOST, WRITE, REQUEST, FUZZ,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_blk_sd_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxBlkSdFuzz.run(seed: options.fetch(:seed))
end
