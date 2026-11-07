# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_path, the path resolver (test/erlang/erx_path_fuzz.erl): random
# trees, tables and paths resolved against the reference model of FreeBSD's vfs_lookup
# (test/erlang/erx_path_model.erl), with the resolver's properties checked on every walk
# and its untrusted inputs fed raw, compiled from source and run on stock's emulator
# (ERX_ERL and ERX_ERLC, the oracle's). It runs the resolver as it is, then each seeded
# fault of docs/design-files.md's Verification item applied to a copy, which the target
# must fail with the failure named for it: that shows the cases reach the code each fault
# breaks and that the comparison and the properties read what they claim to.
module ErxPathFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_path.erl')
  TARGET_SOURCES = %w[erx_path_fuzz erx_path_model erx_path_tree].map do |name|
    File.join(ROOT, "test/erlang/#{name}.erl")
  end.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  DEADLINE_SECONDS = '300'

  # A fault, the text of erx_path it replaces and the replacement, and the failure the
  # target must report for it.
  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  DOTDOT = 'dot(Place, <<"..">>, Rest, St) -> after_dot(up(Place), Rest, St).'
  RUN = "step(Place, Run, Rest, St) ->\n    walk(Place, Run, Rest, St)."
  DOT_STEP = 'step(Place, [], [Dot | Rest], St) ->'
  LINK = "        {link, Joined, Name, After} ->\n"
  LINK_TEXT = "        {ok, Text} when is_binary(Text) ->\n"
  FOLLOWED = 'read(Text, Point ++ Joined, Rest, St#st{links = St#st.links + 1});'

  SEEDS = [
    Seed.new(fault: "a resolver that removes a run's name on .. before its walk",
             anchor: RUN,
             replacement: "step(Place, Run, [<<\"..\">> | Rest], St) ->\n    " \
                          "walk(Place, up(Run), [<<\".\">> | Rest], St);\n#{RUN}",
             failure: 'mismatch'),
    Seed.new(fault: 'a resolver that takes .. before following the link ahead of it',
             anchor: LINK,
             replacement: "        {link, Joined, Name, []} when hd(Rest) =:= <<\"..\">> ->\n" \
                          "            passed(Point ++ Joined ++ [Name], Rest, St);\n#{LINK}",
             failure: 'mismatch'),
    Seed.new(fault: 'a resolver that sends .. to the server',
             anchor: DOTDOT,
             replacement: 'dot(Place, <<"..">>, Rest, St) -> after_dot(Place ++ [<<"..">>], Rest, St).',
             failure: 'walk_names'),
    Seed.new(fault: 'a resolver that answers a last . of delete before checking the name before it',
             anchor: DOT_STEP,
             replacement: "step(_, _, [_], #st{op = Op}) when Op =:= delete; Op =:= rename ->\n    " \
                          "{error, einval};\n#{DOT_STEP}",
             failure: 'mismatch'),
    Seed.new(fault: "a resolver that follows a link's text that is not UTF-8 or holds a NUL",
             anchor: LINK_TEXT,
             replacement: "#{LINK_TEXT}            Next = St#st{links = St#st.links + 1},\n            case text(Text) of\n" \
                          "                true -> read(Text, Point ++ Joined, Rest, Next);\n" \
                          "                false -> next(start(Text, Point ++ Joined), names(Text) ++ Rest, Next)\n" \
                          "            end;\n        {ok, Text} when Text =:= unchecked ->\n",
             failure: 'raw_text'),
    Seed.new(fault: "a resolver that reads the namespace's term again at a link",
             anchor: FOLLOWED,
             replacement: 'read(Text, Point ++ Joined, Rest, St#st{links = St#st.links + 1, ' \
                          'table = persistent_term:get(erx_ns, St#st.table)});',
             failure: 'mismatch')
  ].freeze

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |fault|
      raise "no anchor for #{fault.fault} in #{MODULE_SOURCE}" unless source.scan(fault.anchor).size == 1
    end

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ resolutions ok$/)
    SEEDS.each do |fault|
      output, status = fuzz(source.sub(fault.anchor, fault.replacement), seed: seed)
      abort("#{fault.fault} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts "erx_path agrees with FreeBSD's vfs_lookup model and keeps its properties over every case, " \
         "and each of #{SEEDS.size} seeded faults fails"
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-path-fuzz') do |work|
      module_path = File.join(work, 'erx_path.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path,
                                       *TARGET_SOURCES, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_path_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxPathFuzz.run(seed: seed)
end
