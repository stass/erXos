# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

# The fuzz target of root's passphrase line, erx_boot_passphrase:decode/1, and its
# record, erx_passphrase_hash:decode/1 (docs/design-ssh.md, "Root's passphrase on
# the medium"): test/erlang/erx_boot_passphrase_fuzz.erl over the modules as they
# are, then over each seeded copy, which must fail with the verdict it names.

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/fuzz_warm'

module ErxBootPassphraseFuzz
  ROOT = File.expand_path('../..', __dir__)
  LINE = 'erlang/apps/erx/src/erx_boot_passphrase.erl'
  HASH = 'erlang/apps/erx/src/erx_passphrase_hash.erl'
  FUZZ = 'test/erlang/erx_boot_passphrase_fuzz.erl'
  DEADLINE_SECONDS = '120'
  # Each seeded copy: its file, the text it replaces, the text it plants, the verdict.
  MUTANTS = {
    'a hash group read in the wrong order' => [LINE, '{21, 1, 11}', '{1, 21, 11}', 'disagrees_with_reference'],
    'a record of any rounds taken' => [HASH, 'Rounds >= ?ROUNDS_MIN andalso Rounds =< ?ROUNDS_MAX', 'Rounds >= ?ROUNDS_MIN',
                                       'record_out_of_bounds'],
    'the length bound dropped' => [LINE, 'decode(File) when is_binary(File), byte_size(File) > ?FILE_MAX ->',
                                   'decode(File) when is_binary(File), byte_size(File) > 4 * ?FILE_MAX ->',
                                   'long_file_not_too_long']
  }.freeze

  module_function

  def run(seed:)
    sources = [LINE, HASH].to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    MUTANTS.each_value { |path, from, _to, _verdict| raise "#{from.inspect} not in #{path}" unless sources[path].include?(from) }

    output, status = fuzz(sources, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    MUTANTS.each do |name, (path, from, to, verdict)|
      output, status = fuzz(sources.merge(path => sources[path].sub(from, to)), seed: seed)
      abort("#{name} passed:\n#{output}") if status.success? || !output.match?(Regexp.new(verdict))
    end
    puts "erx_boot_passphrase and erx_passphrase_hash agree with their reference, and no seeded copy does (#{MUTANTS.keys.join('; ')})"
  end

  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-boot-passphrase-fuzz') do |work|
      paths = sources.map do |path, text|
        File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *paths, File.join(ROOT, FUZZ),
                                       Erx::FuzzWarm::SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_boot_passphrase_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBootPassphraseFuzz.run(seed: seed)
end
