# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_fs_grant, the pure core of each erx_fs grant: random sequences of
# frames and local messages, decoded by erx_9p_grammar, through the core over
# erx_fs_test_tree, with every reply checked against the grammar and the core's bounds
# checked after every step (test/erlang/erx_fs_grant_fuzz.erl). Compiled from source and
# run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the core as it is,
# then a copy whose fid pool admits one fid more, which the pool check must catch: that
# shows the sequences reach the pool's bound and the check reads it.
module ErxFsGrantFuzz
  ROOT = File.expand_path('../..', __dir__)
  GRANT = 'erlang/apps/erx_files/src/erx_fs_grant.erl'
  SOURCES = [GRANT, 'otp/erts/preloaded/src/erx_9p_grammar.erl', 'test/erlang/erx_fs_test_tree.erl',
             'test/erlang/erx_fs_grant_fuzz.erl'].freeze
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')
  POOL_BOUND = 'map_size(Fids) >= Pool -> {error, emfile};'
  WRONG_POOL_BOUND = 'map_size(Fids) > Pool -> {error, emfile};'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(File.join(ROOT, GRANT))
    raise "no pool bound in #{GRANT}" unless source.include?(POOL_BOUND)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ sequences ok$/)
    puts output
    output, status = fuzz(source.sub(POOL_BOUND, WRONG_POOL_BOUND), seed: seed)
    abort("a pool admitting one fid more passed:\n#{output}") if status.success? || !output.include?('check_failed')
    puts 'erx_fs_grant answers every frame as the grammar allows and keeps its bounds, ' \
         'and a pool admitting one fid more does not'
  end

  # In a directory of its own, removed with whatever a failed sequence left in it.
  def fuzz(grant_text, seed:)
    Dir.mktmpdir('erx-fs-grant-fuzz') do |work|
      grant_path = File.join(work, File.basename(GRANT))
      File.binwrite(grant_path, grant_text)
      paths = [grant_path, *SOURCES.drop(1).map { |source| File.join(ROOT, source) }]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, *paths, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_fs_grant_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxFsGrantFuzz.run(seed: seed)
end
