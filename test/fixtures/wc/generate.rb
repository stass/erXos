# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Writes the wc golden fixtures that test/erlang/erx_cmd_wc_tests.erl reads
# into DIR: the inputs, and `expected`, the standard output of macOS's
# /usr/bin/wc (FreeBSD's wc, text_cmds-199) for each case, in a UTF-8
# locale. Run on macOS as `ruby test/fixtures/wc/generate.rb test/fixtures/wc`.
require 'open3'
require 'fileutils'

dir = ARGV.fetch(0)
FileUtils.mkdir_p(dir)

INPUTS = {
  'words' => "The quick  brown\tfox\n\njumps over\vthe lazy dog\r\n  leading and trailing  \n",
  'utf8' => "caf\u{E9} na\u{EF}ve\n\u{65E5}\u{672C}\u{8A9E}\u{3000}\u{30C6}\u{30AD}\u{30B9}\u{30C8}\n" \
            "a\u{A0}b c\u{2003}d e\u{200B}f g\u0085h i\u{2028}j\n\u{1F600} emoji\n",
  'bad' => "ok \xff\xfe bytes\n\xc0\x80 overlong \xed\xa0\x80 surrogate\n\xe2\x82 cut\ntrail \xe2\x82".b,
  'noeol' => "short\nthe longest line here\nlast line without a newline is longer than all",
  'empty' => ''
}.freeze

CASES = [
  %w[words], %w[-l words], %w[-w words], %w[-c words], %w[-m words], %w[-L words], %w[-Llwc words],
  %w[utf8], %w[-m utf8], %w[-cm utf8], %w[-mc utf8], %w[-w utf8], %w[-mw utf8], %w[-L utf8], %w[-mL utf8],
  %w[bad], %w[-m bad], %w[-mw bad], %w[-mL bad], %w[-L noeol], %w[-lL noeol], %w[empty],
  %w[words utf8 bad noeol empty], %w[-mL words utf8 bad], %w[-w -l utf8 words]
].freeze

INPUTS.each { |name, bytes| File.binwrite(File.join(dir, name), bytes) }

expected = CASES.map do |args|
  out, _err, _status = Open3.capture3({ 'LC_ALL' => 'en_US.UTF-8' }, '/usr/bin/wc', *args, chdir: dir)
  "$ wc #{args.join(' ')}\n#{out}"
end
File.binwrite(File.join(dir, 'expected'), expected.join)
