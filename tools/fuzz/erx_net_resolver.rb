#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs test/erlang/erx_net_resolver_fuzz.erl, the fuzz target of name resolution's
# untrusted inputs (docs/design-network-stack.md, "Name resolution"), for one target,
# against the sources as they are and against a copy with the target's seeded fault,
# which must fail it:
#   config  erx_inet:resolver_config/1, with its label bound of 63 bytes dropped;
#   dns     inet_dns:decode/1, whose too-short header raises instead of throwing;
#   host    erx_cmd_host's lines, with the field escape left out.

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

module ErxNetResolverFuzz
  ROOT = File.expand_path('../..', __dir__)
  KERNEL = File.join(ROOT, 'otp/lib/kernel')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_net_resolver_fuzz.erl')
  DEADLINE_SECONDS = '300'
  PASSED = /^fuzz: \d+ inputs ok$/

  Fault = Data.define(:what, :source, :anchor, :replacement, :marker)

  FAULTS = {
    'config' => Fault.new(what: 'a check without the label bound', source: 'erlang/apps/erx_net_client/src/erx_inet.erl',
                          anchor: 'label(Label) when byte_size(Label) >= 1, byte_size(Label) =< 63 ->',
                          replacement: 'label(Label) when byte_size(Label) >= 1 ->', marker: 'config_accepted_bad'),
    'dns' => Fault.new(what: 'a decoder whose short header raises', source: 'otp/lib/kernel/src/inet_dns.erl',
                       anchor: "do_decode(<<_/binary>>, _Mdns) ->\n    throw(?DECODE_ERROR).",
                       replacement: "do_decode(<<_/binary>>, _Mdns) ->\n    error(?DECODE_ERROR).", marker: 'decode_raised'),
    'host' => Fault.new(what: 'host without the field escape', source: 'erlang/apps/erx_shell/src/erx_cmd_host.erl',
                        anchor: "name(Name) ->\n    erx_text:escape_field(list_to_binary(Name)).",
                        replacement: "name(Name) ->\n    list_to_binary(Name).", marker: 'host_unescaped')
  }.freeze

  SOURCES = ['build/gen/erlang/apps/erx/src/erx_text_tables.erl', 'erlang/apps/erx/src/erx_text.erl',
             'erlang/apps/erx_shell/src/erx_cmd.erl', 'erlang/apps/erx_shell/src/erx_cmd_host.erl',
             'erlang/apps/erx_net_client/src/erx_inet.erl', 'otp/lib/kernel/src/inet_dns.erl'].freeze

  module_function

  def run(target:, seed:)
    fault = FAULTS.fetch(target)
    Erx::Generated.ensure(root: ROOT)
    texts = SOURCES.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    output, status = fuzz(texts, target: target, seed: seed)
    abort(output) unless status.success? && output.match?(PASSED)
    raise "no #{fault.anchor} in #{fault.source}" unless texts.fetch(fault.source).include?(fault.anchor)

    faulty = texts.merge(fault.source => texts.fetch(fault.source).sub(fault.anchor) { fault.replacement })
    output, = fuzz(faulty, target: target, seed: seed)
    abort("#{fault.what} passed:\n#{output}") if output.match?(PASSED) || !output.include?(fault.marker)
    puts "erx_net_resolver #{target}: every input passed, and #{fault.what} failed with #{fault.marker}"
  end

  # In a directory of its own, which also takes the crash dump of a failed run. The
  # kernel's inet_dns is replaced by the copy compiled here, so the run is -nostick.
  def fuzz(texts, target:, seed:)
    Dir.mktmpdir('erx-net-resolver-fuzz') do |work|
      paths = texts.map { |path, text| File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) } }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', File.join(KERNEL, 'src'), '-I', File.join(KERNEL, 'include'),
                                       '-o', work, *paths, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-nostick', '-pa', work,
                      '-eval', 'code:purge(inet_dns), {module, inet_dns} = code:load_abs("inet_dns")',
                      '-run', 'erx_net_resolver_fuzz', 'run', target, seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  target = nil
  seed = 1
  OptionParser.new do |flags|
    flags.on('--target NAME', ErxNetResolverFuzz::FAULTS.keys) { |value| target = value }
    flags.on('--seed N', Integer) { |value| seed = value }
  end.parse!
  abort("usage: #{$PROGRAM_NAME} --target #{ErxNetResolverFuzz::FAULTS.keys.join('|')} [--seed N]") unless target
  ErxNetResolverFuzz.run(target: target, seed: seed)
end
