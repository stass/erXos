# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz targets of the Raspberry Pi 4 Ethernet driver's parsers of what its
# devices wrote: erx_genet_rx's and erx_genet_core's reading of a receive completion's
# flags and bytes (test/erlang/erx_genet_rx_fuzz.erl), and erx_mdio's and erx_phy_c22's
# decoding of MDIO command words and PHY register words
# (test/erlang/erx_phy_word_fuzz.erl). Each compiles its modules from source and
# runs them alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it
# needs no hosted build. Each runs the modules as they are, then each seeded copy
# of its mutants, each with one rule broken, which must fail with a disagreement.
module ErxGenetFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORES = File.join(ROOT, 'erlang/apps/erx_net/erxos')
  # The cores include the generated erx_hw_genet.hrl, in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  Target = Data.define(:name, :modules, :mutants)
  # For each target: its Erlang module, the cores it compiles, and what each
  # seeded copy says, with the core, the text it replaces and the text it plants.
  TARGETS = [
    Target.new(name: 'erx_genet_rx_fuzz', modules: %w[erx_genet_rx erx_genet_core],
               mutants: {
                 'a frame longer than the buffer' =>
                   ['erx_genet_rx', 'byte_size(Bytes) > ?BUFFER_BYTES -> {drop, too_long};', ''],
                 'the padding kept in the frame' =>
                   ['erx_genet_rx', 'binary:part(Bytes, ?PAD, byte_size(Bytes) - ?PAD)',
                    'binary:part(Bytes, 0, byte_size(Bytes) - ?PAD)'],
                 'only the receive-error bit dropping a frame' =>
                   ['erx_genet_rx', 'Flags band ?STATUS_ERROR_MASK =/= 0', 'Flags band 16#0004 =/= 0'],
                 'a frame past the MTU passed up' =>
                   ['erx_genet_core', '{frame, _Long} -> {[{dropped, too_long} | Drops], Frames};',
                    '{frame, Long} -> {Drops, [Long | Frames]};']
               }),
    Target.new(name: 'erx_phy_word_fuzz', modules: %w[erx_mdio erx_phy_c22],
               mutants: {
                 'a failed read taken as data' =>
                   ['erx_mdio', 'when Word band ?READ_FAILED =/= 0', 'when Word band ?READ_FAILED =:= -1'],
                 'a half-duplex resolution taken as a speed' =>
                   ['erx_phy_c22', "        ?RES_10FD -> 10;\n        _ -> none", "        ?RES_10FD -> 10;\n        _ -> 10"]
               })
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    TARGETS.each do |target|
      sources = target.modules.to_h { |name| [name, File.binread(File.join(CORES, "#{name}.erl"))] }
      target.mutants.each_value do |name, from, _to|
        raise "#{from.inspect} is not in #{name}.erl" unless sources.fetch(name).include?(from)
      end

      output, status = fuzz(target.name, sources, seed: seed)
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
      target.mutants.each do |what, (name, from, to)|
        output, status = fuzz(target.name, sources.merge(name => sources.fetch(name).sub(from, to)), seed: seed)
        abort("#{target.name} accepting #{what} passed:\n#{output}") if status.success? ||
                                                                       !output.include?('disagrees_with_reference')
      end
      puts "#{target.name} agrees with its reference, and no copy accepting #{target.mutants.keys.join(' or ')} does"
    end
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(target, sources, seed:)
    Dir.mktmpdir('erx-genet-fuzz') do |work|
      paths = sources.map do |name, text|
        File.join(work, "#{name}.erl").tap { |path| File.binwrite(path, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, *paths,
                                       File.join(ROOT, 'test/erlang', "#{target}.erl"), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', target, 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxGenetFuzz.run(seed: seed)
end
