# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of a Bluetooth link's ACL input, erx_bt_link_core:step/3 over the
# packets a radio peer sends and what the link's other parties send
# (test/erlang/erx_bt_link_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# sources as they are, then, for each seeded fault, a copy of the module with the fault in
# place, which must fail with the verdict the fault breaks.
module ErxBtLinkFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_bt/src/erx_bt_link_core.erl'
  SOURCES = %w[erx_l2cap erx_att erx_gatt_db erx_gatt_gate erx_gatt_server erx_smp erx_smp_core erx_smp_crypto]
            .map { |name| "erlang/apps/erx_bt/src/#{name}.erl" }
            .push(CORE, 'test/erlang/host_bytes/erx_bytes.erl', 'test/erlang/erx_bt_link_fuzz.erl').freeze
  # Each compile and run is under this deadline, and tools/erx gives the whole runner 300.
  DEADLINE_SECONDS = '60'

  # A seeded fault: the module's anchor replaced, and the error term the run must fail
  # with, matched with its opening brace so one verdict is not read inside another.
  Fault = Data.define(:fault, :anchor, :replacement, :verdict)

  FAULTS = [
    Fault.new(fault: 'a frame on a channel the link does not serve not taken',
              anchor: 'channel(_Cid, _Payload, _Now, #core{dropped = Dropped} = Core) ->',
              replacement: 'channel(16#7FFF, _Payload, _Now, #core{dropped = Dropped} = Core) ->',
              verdict: '{core_raised,'),
    Fault.new(fault: "the hand-over past the link's share of the controller's buffers",
              anchor: 'when Outstanding >= Share ->',
              replacement: 'when Outstanding >= Share + 1 ->',
              verdict: '{over_share,'),
    Fault.new(fault: "a controller message's step without its `taken`",
              anchor: '    {[{hci, taken} | Actions], Next};',
              replacement: '    {Actions, Next};',
              verdict: '{not_taken,'),
    Fault.new(fault: "a configuration write kept by the store for a link that is not its bond's",
              anchor: "configuration(Ref, _Key, _Kind, Now, #core{bond = none} = Core) ->\n" \
                      '    att(erx_gatt_server:reply(Ref, ok, server(Core), Core#core.bearer), Now, Core).',
              replacement: "configuration(_Ref, Key, Kind, _Now, #core{bond = none} = Core) ->\n" \
                           '    {[{store, {subscriptions, #{Key => Kind}}}], Core}.',
              verdict: '{store_write_not_bonded,'),
    Fault.new(fault: "a bonded link's security told to the registry without the bond's identity",
              anchor: 'bond_security({kept, Identity, _Write}) -> #{bonded => true, identity => Identity};',
              replacement: 'bond_security({kept, _Identity, _Write}) -> #{bonded => true};',
              verdict: '{identity_not_bonded,')
  ].freeze

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    output, status = fuzz({}, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, /)
    FAULTS.each { |fault| run_fault(fault, seed: seed) }
    puts output[/^fuzz: .*$/]
    puts "erx_bt_link_core takes every ACL packet and every other party's message without a raise or an atom, " \
         "and #{FAULTS.size} seeded faults each fail their verdict"
  end

  def run_fault(fault, seed:)
    source = File.binread(File.join(ROOT, CORE))
    raise "seed anchor for #{fault.fault} is not unique" unless source.scan(fault.anchor).size == 1

    output, status = fuzz({ CORE => source.sub(fault.anchor) { fault.replacement } }, seed: seed)
    abort("#{fault.fault}: the fuzz run passed:\n#{output}") if status.success? || !output.include?(fault.verdict)
  end

  # In a directory of its own, which also takes the crash dump of a failed round; a
  # replaced module is compiled from its copy there.
  def fuzz(replaced, seed:)
    Dir.mktmpdir('erx-bt-link-fuzz') do |work|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.binwrite(path, replaced.fetch(source)) }
      end
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', include,
                                       '-o', work, *sources, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_link_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtLinkFuzz.run(seed: seed)
end
