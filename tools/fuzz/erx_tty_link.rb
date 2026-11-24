# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=900

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_tty_link, the tty's side of the messages between a session's tty
# and its master, whose messages from another domain are untrusted (docs/design-live.md,
# "Between domains"). It is compiled from source and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's), as the module is and then as copies that each break one
# guarantee, each of which must fail with the property that guards it: that shows the runs
# reach the bounds of the messages from the master and that the checks catch a break.
module ErxTtyLinkFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_session/src/erx_tty_link.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_tty_link_fuzz.erl')
  # erx_tty_link takes its room from erx_tty:master_room/0.
  TTY_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_tty.erl')
  # The SSH line core, whose requests the same target feeds (docs/design-ssh.md, "Sessions, ttys
  # and shells").
  LINE_SOURCE = File.join(ROOT, 'erlang/apps/erx_tty_line/src/erx_tty_line_core.erl')
  # The core takes a shell's TERM from erx_text_tables, which the build generates from
  # abi/terminal.txt into build/gen.
  TEXT_TABLES = 'erlang/apps/erx/src/erx_text_tables.erl'
  # The modules take their bounds from the generated ABI header (abi/services/console.txt
  # and tty_line.txt).
  INCLUDE = 'erlang/apps/erx/include'
  # A broken guarantee: the text that keeps it, what replaces it, and the property that must
  # then fail, as the target names it.
  Seed = Data.define(:text, :broken, :property)
  SEEDED = {
    'the 4 KiB input bound' => Seed.new(text: 'when is_binary(Bytes), byte_size(Bytes) =< ?MAX_INPUT ->',
                                        broken: 'when is_binary(Bytes) ->',
                                        property: 'input_over_bound'),
    'the window size bounds' => Seed.new(text: 'when is_integer(Rows), Rows >= 1, Rows =< ?ERX_CONSOLE_SIDE_MAX,',
                                         broken: 'when is_integer(Rows), Rows >= 0,',
                                         property: 'size_out_of_range'),
    'the 4 KiB held bound' => Seed.new(text: 'Room = ?MAX_HELD - held(L),', broken: 'Room = 2 * ?MAX_HELD - held(L),',
                                       property: 'held_over_bound'),
    'the output numbering' => Seed.new(text: 'held = <<>>, next = N + 1}', broken: 'held = <<>>, next = N + 2}',
                                       property: 'numbering'),
    'the answer to a write held whole' => Seed.new(text: '<<>> -> fill(Next#link{waiting = Rest}, [done(Writer) | Done]);',
                                                   broken: '<<>> -> fill(Next#link{waiting = Rest}, Done);',
                                                   property: 'write_unanswered'),
    'output held while stopped' => Seed.new(text: '-> Master =:= present andalso not Stopped.',
                                            broken: '-> Master =:= present.',
                                            property: 'output_while_stopped'),
    'a flush dropping what is held' => Seed.new(text: '{Done, L#link{held = <<>>, waiting = queue:new(), unowned = 0}}.',
                                                broken: '{Done, L#link{waiting = queue:new(), unowned = 0}}.',
                                                property: 'sent_not_written'),
    'room/1 counting the outstanding output' => Seed.new(text: '{?MAX_HELD - held(L), outstanding_size(Outstanding), Stopped}',
                                                         broken: '{?MAX_HELD - held(L), byte_size(L#link.held), Stopped}',
                                                         property: 'room_wrong'),
    'room/1 naming the outstanding output' => Seed.new(text: '{?MAX_HELD - held(L), outstanding_size(Outstanding), Stopped}',
                                                       broken: '{?MAX_HELD - held(L), 0, Stopped}',
                                                       property: 'room_wrong')
  }.freeze
  LINE_SEEDED = {
    "the channel being the peer's" => Seed.new(text: 'case {valid_run(Run), Owner(Channel) =:= Peer} of',
                                               broken: 'case {valid_run(Run), is_function(Owner, 1)} of',
                                               property: 'foreign_channel'),
    'a command holding no NUL' => Seed.new(text: 'binary:match(Command, <<0>>) =:= nomatch;', broken: 'true;',
                                           property: 'bad_run'),
    'ten channels at most' => Seed.new(text: 'when map_size(Ttys) >= ?ERX_TTY_LINE_MAX_CHANNELS ->',
                                       broken: 'when map_size(Ttys) > ?ERX_TTY_LINE_MAX_CHANNELS ->',
                                       property: 'over_limit'),
    'a zero side taken as the default' => Seed.new(text: 'side(0, Default) -> Default;',
                                                   broken: 'side(0, _Default) -> 0;', property: 'size_out_of_range')
  }.freeze
  # Each module under test, and the guarantees seeded out of it.
  TARGETS = { MODULE_SOURCE => SEEDED, LINE_SOURCE => LINE_SEEDED }.freeze
  DEADLINE_SECONDS = '60'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    sources = TARGETS.keys.to_h { |path| [path, File.binread(path)] }
    output, status = fuzz(sources, seed: seed)
    abort(output[0, 4000]) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    TARGETS.each do |path, seeds|
      source = sources.fetch(path)
      seeds.each do |guarantee, planted|
        raise "no #{guarantee} (#{planted.text}) in #{path}" unless source.include?(planted.text)

        output, status = fuzz(sources.merge(path => source.sub(planted.text, planted.broken)), seed: seed)
        unless !status.success? && output.include?("fuzz_failure,#{planted.property}")
          abort("#{File.basename(path, '.erl')} without #{guarantee} did not fail #{planted.property}:\n" \
                "#{output[0, 4000]}")
        end
      end
    end
    puts 'erx_tty_link and erx_tty_line_core keep their guarantees, and copies without ' \
         "#{TARGETS.values.flat_map(&:keys).join(', ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round: each
  # module under test as sources holds it, and the target.
  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-tty-link-fuzz') do |work|
      module_paths = sources.map do |path, text|
        File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) }
      end
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'),
                                       '-I', Erx::Generated.path(INCLUDE, root: ROOT), '-o', work,
                                       *module_paths, TTY_SOURCE, Erx::Generated.path(TEXT_TABLES, root: ROOT),
                                       TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_tty_link_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxTtyLinkFuzz.run(seed: seed)
end
