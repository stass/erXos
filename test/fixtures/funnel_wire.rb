# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'generated_tree'
require_relative 'etf_wire'

# Control terms of the funnel's grammar as wire bytes, one builder per
# operation, with the pids and references at the host erxos.
module FunnelWire
  include EtfWire
  module_function

  def from = EtfWire.pid('web@erxos', 5, 0, 3)
  def to = EtfWire.pid('system@erxos', 9, 0, 1)
  def reference = EtfWire.ref('system@erxos', 1, [1, 2, 3, 4])
  def ctl(*elements) = "\x83".b + EtfWire.tuple(*elements)
  def op(number) = EtfWire.small(number)
  def mfa = EtfWire.tuple(EtfWire.atom('m'), EtfWire.atom('f'), EtfWire.small(2))
  def options = EtfWire.list([EtfWire.atom('link'), EtfWire.tuple(EtfWire.atom('priority'), EtfWire.atom('high')),
                              EtfWire.tuple(EtfWire.atom('max_heap_size'),
                                            EtfWire.map([EtfWire.atom('size'), EtfWire.small(100)],
                                                        [EtfWire.atom('kill'), EtfWire.atom('true')]))])

  # One well-formed control term of each operation, and whether a payload
  # follows it.
  def every_operation
    {
      'LINK' => [ctl(op(1), from, to), false], 'GROUP_LEADER' => [ctl(op(7), from, to), false],
      'MONITOR_P' => [ctl(op(19), from, to, reference), false],
      'DEMONITOR_P' => [ctl(op(20), from, to, reference), false],
      'SEND_SENDER' => [ctl(op(22), from, to), true], 'PAYLOAD_EXIT' => [ctl(op(24), from, to), true],
      'PAYLOAD_EXIT2' => [ctl(op(26), from, to), true],
      'PAYLOAD_MONITOR_P_EXIT' => [ctl(op(28), from, to, reference), true],
      'SPAWN_REQUEST' => [ctl(op(29), reference, from, to, mfa, options), true],
      'SPAWN_REPLY' => [ctl(op(31), reference, to, EtfWire.small(0), from), false],
      'SPAWN_REPLY error' => [ctl(op(31), reference, to, EtfWire.small(1), EtfWire.atom('badarg')), false],
      'ALIAS_SEND' => [ctl(op(33), from, reference), true],
      'UNLINK_ID' => [ctl(op(35), EtfWire.small(1), from, to), false],
      'UNLINK_ID_ACK' => [ctl(op(36), EtfWire.int(70_000), from, to), false]
    }
  end
end

# test/fixtures/funnel_driver.c, built once with the given flags, run over a
# list of requests in its format; returns one answer per request.
class FunnelDriver
  SOURCES = %w[liberx/erx_funnel.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
               kernel/crypto/blake3/blake3_portable.c test/fixtures/funnel_driver.c].freeze

  def initialize(root:, runner:, directory:, flags: [])
    @root = root
    @runner = runner
    @directory = directory
    @flags = flags
  end

  def check(requests)
    requests_file = File.join(@directory, 'funnel-requests')
    answers_file = File.join(@directory, 'funnel-answers')
    File.write(requests_file, requests.map { |line| "#{line}\n" }.join)
    @runner.run([program, requests_file, answers_file], name: 'funnel-driver', deadline: 300)
    File.read(answers_file).lines(chomp: true).tap do |lines|
      raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size
    end
  end

  private

  def program
    @program ||= File.join(@directory, 'funnel_driver').tap do |output|
      @runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror',
                   '-pedantic', '-O1', '-g', *@flags, *Erx::Generated.include_flags(root: @root),
                   '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                   *SOURCES.map { |source| File.join(@root, source) },
                   Erx::Generated.path('liberx/generated/abi_reader.c', root: @root), '-o', output],
                  name: 'compile-funnel-driver', deadline: 120)
    end
  end
end
