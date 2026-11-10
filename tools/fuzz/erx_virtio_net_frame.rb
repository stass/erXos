# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the network driver's cut of what a device wrote into a receive buffer,
# erx_virtio_net:frames/2: the device header skipped, then the frame bounded below by an
# Ethernet header and above by the MTU. It compiles the driver from source and runs it alone
# on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build; the
# driver's calls into erx_device and the stack are never made. It runs the module as it is,
# then each seeded copy of MUTANTS, each with one bound removed, which must fail.
module ErxVirtioNetFrameFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_net/erxos/erx_virtio_net.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_virtio_net_frame_fuzz.erl')
  INCLUDES = [File.join(ROOT, 'build/gen/erlang/apps/erx/include'), File.join(ROOT, 'erlang/apps/erx_net/include')].freeze
  # What each seeded copy says, the text it replaces and the text it plants.
  MUTANTS = {
    'a frame shorter than an Ethernet header' => [' when byte_size(Frame) >= ?ETHER_HDR_LEN ->', ' ->'],
    'a frame longer than the MTU' => ['byte_size(Frame) =< Mtu + ?ETHER_HDR_LEN', 'is_binary(Frame)']
  }.freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    MUTANTS.each_value { |from, _to| raise "#{from.inspect} is not in #{MODULE_SOURCE}" unless source.include?(from) }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    MUTANTS.each do |name, (from, to)|
      output, status = fuzz(source.sub(from, to), seed: seed)
      abort("accepting #{name} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts "erx_virtio_net:frames/2 agrees with its reference, and no copy accepting #{MUTANTS.keys.join(' or ')} does"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-virtio-net-frame-fuzz') do |work|
      module_path = File.join(work, 'erx_virtio_net.erl')
      File.binwrite(module_path, module_text)
      includes = INCLUDES.flat_map { |dir| ['-I', dir] }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *includes, '-o', work, module_path, TARGET_SOURCE,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_virtio_net_frame_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxVirtioNetFrameFuzz.run(seed: seed)
end
