# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_fs_grant, the pure core of each erx_fs grant: random sequences of
# frames and local messages, decoded by erx_9p_grammar, through the core over
# erx_fs_test_tree, with every reply checked against the grammar and the core's bounds
# checked after every step (test/erlang/erx_fs_grant_fuzz.erl), for grants of the server's
# own domain and of another. Compiled from source and run on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's). It runs the core as it is, then each seeded fault, which a check
# must catch: a fid pool admitting one fid more shows the sequences reach the pool's bound
# and the check reads it; a grant taking any domain's names for another domain's shows
# they send a third domain's names to a grant of another domain, and the reply check
# reads whose alias each reply goes to.
module ErxFsGrantFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  GRANT = 'erlang/apps/erx_files/src/erx_fs_grant.erl'
  SOURCES = [GRANT, 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl', 'test/erlang/erx_fs_test_tree.erl',
             'test/erlang/erx_fs_grant_fuzz.erl', 'test/erlang/stand_in/erx_dist.erl'].freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Fault = Data.define(:name, :from, :to)
  FAULTS = [
    Fault.new(name: 'a pool admitting one fid more',
              from: 'map_size(Fids) >= Pool -> {error, emfile};', to: 'map_size(Fids) > Pool -> {error, emfile};'),
    Fault.new(name: "a grant taking any domain's names for another domain's",
              from: 'of_client(Name, Client) -> erx_dist:owner(Name) =:= Client.',
              to: 'of_client(Name, Client) -> erx_dist:owner(Name) > 0 andalso is_integer(Client).')
  ].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(File.join(ROOT, GRANT))
    FAULTS.each { |fault| raise "#{fault.name}: passage not found once in #{GRANT}" unless source.scan(fault.from).size == 1 }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ sequences ok$/)
    puts output
    FAULTS.each do |fault|
      output, status = fuzz(source.sub(fault.from, fault.to), seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?('check_failed')
    end
    puts 'erx_fs_grant answers every frame as the grammar allows and keeps its bounds, ' \
         "and a check catches each seeded fault: #{FAULTS.map(&:name).join('; ')}"
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
