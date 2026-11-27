# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'socket'
require 'tmpdir'
require_relative '../../tools/lib/erx/fault_probe'

# The fault probe's judge (tools/lib/erx/fault_probe.rb) over hand-written transcripts: a
# kind is verified only when the fault stopped its own operation, the rest went on, and the
# operation completed once lifted; and the Qmp commands its actions send.
class FaultProbeTest < Minitest::Test
  Probe = Erx::FaultProbe
  CRC = 0x12345678
  INJECTED = 10.0
  LIFTED = 13.0
  ENDED = 16.0

  def window(kind) = Probe::Window.new(kind: kind, injected: INJECTED, lifted: LIFTED, ended: ENDED)

  # signal seen every `every` seconds over (from, to), each with values.
  def steady(signal, from, to, every:, values: [])
    (from + every).step(to, every).map { |at| Probe::Observation.new(at: at, signal: signal, values: values) }
  end

  def seen(signal, at, *values) = Probe::Observation.new(at: at, signal: signal, values: values)

  # A guest whose four threads run throughout, before the window and to its end, less the
  # signals in without.
  def healthy(without: [])
    { tick: steady(:tick, 8.0, ENDED, every: 0.1), read: steady(:read, 8.0, ENDED, every: 0.05, values: [1, CRC]),
      console: steady(:console, 8.0, ENDED, every: 0.1), carrier: [seen(:carrier, 8.0, 1)] }
      .reject { |signal, _| without.include?(signal) }.values.flatten
  end

  def judge(kind, observations) = Probe.judge(window(kind), observations.sort_by(&:at), expected_crc: CRC)

  def assert_verdict(verdict, status, reason = nil)
    assert_equal status, verdict.status, verdict.reason
    assert_match reason, verdict.reason if reason
  end

  # Reads stop while the fault holds, then the held one answers with the time it waited.
  def stalled_reads(resumed: true)
    reads = steady(:read, 8.0, INJECTED, every: 0.05, values: [1, CRC])
    return reads unless resumed

    reads + [seen(:read, LIFTED + 0.01, 2950, CRC)] + steady(:read, LIFTED + 0.01, ENDED, every: 0.05, values: [1, CRC])
  end

  def test_a_block_stall_that_holds_the_read_and_answers_it_is_verified
    assert_verdict judge(:block_stall, healthy(without: [:read]) + stalled_reads), :verified
  end

  def test_a_held_read_that_never_answers_after_the_lift_is_unsupported
    verdict = judge(:block_stall, healthy(without: [:read]) + stalled_reads(resumed: false))
    assert_verdict verdict, :unsupported, /no read completed after the lift/
  end

  def test_a_fault_that_also_stops_an_untargeted_device_is_unsupported
    console = steady(:console, 8.0, INJECTED, every: 0.1) + steady(:console, LIFTED, ENDED, every: 0.1)
    verdict = judge(:block_stall, healthy(without: %i[read console]) + stalled_reads + console)
    assert_verdict verdict, :unsupported, /0 console lines arrived while block_stall held/
  end

  def test_reads_that_go_on_under_a_block_stall_are_unsupported
    assert_verdict judge(:block_stall, healthy), :unsupported, /reads completed while the fault held/
  end

  def test_a_fast_read_after_the_lift_is_not_the_held_one
    reads = steady(:read, 8.0, INJECTED, every: 0.05, values: [1, CRC]) +
            steady(:read, LIFTED, ENDED, every: 0.05, values: [1, CRC])
    assert_verdict judge(:block_stall, healthy(without: [:read]) + reads), :unsupported, /not the held one/
  end

  def test_a_read_that_answers_other_data_is_unsupported
    reads = stalled_reads.map { |read| read.at > LIFTED ? read.with(values: [read.values[0], CRC ^ 1]) : read }
    assert_verdict judge(:block_stall, healthy(without: [:read]) + reads), :unsupported, /data the probe did not write/
  end

  def test_link_down_is_verified_by_carrier_going_down_and_back
    carrier = [seen(:carrier, INJECTED + 0.05, 0), seen(:carrier, LIFTED + 0.05, 1)]
    assert_verdict judge(:link_down, healthy + carrier), :verified
  end

  def test_link_down_without_the_carrier_coming_back_is_unsupported
    verdict = judge(:link_down, healthy + [seen(:carrier, INJECTED + 0.05, 0)])
    assert_verdict verdict, :unsupported, /never saw its carrier come back/
  end

  def test_a_carrier_drop_under_another_kind_is_unsupported
    console = steady(:console, 8.0, INJECTED, every: 0.1) + steady(:console, LIFTED, ENDED, every: 0.1)
    observations = healthy(without: [:console]) + console + [seen(:carrier, 11.0, 0), seen(:carrier, 11.5, 1)]
    assert_verdict judge(:chardev_stop, observations), :unsupported, /carrier was not up while chardev_stop held/
  end

  def test_a_carrier_that_comes_back_while_the_fault_holds_is_unsupported
    carrier = [seen(:carrier, INJECTED + 0.05, 0), seen(:carrier, 11.0, 1), seen(:carrier, 12.0, 0), seen(:carrier, LIFTED + 0.05, 1)]
    assert_verdict judge(:link_down, healthy + carrier), :unsupported, /come back while the fault held/
  end

  def test_a_failed_lift_leaves_the_later_kinds_not_attempted
    failed = Probe::Refusal.new(kind: :block_stall, answer: 'lift: QEMU did not answer within the deadline', leaves_state: true)
    assert_equal 'not attempted: block_stall left QEMU\'s state unknown', Probe.spoiled(failed).answer
    assert_nil Probe.spoiled(failed.with(leaves_state: false))
    assert_nil Probe.spoiled(window(:block_stall))
  end

  def test_a_silent_tick_is_unsupported
    ticks = healthy.reject { |observation| observation.signal == :tick && observation.at.between?(14.0, 15.5) }
    carrier = [seen(:carrier, INJECTED + 0.05, 0), seen(:carrier, LIFTED + 0.05, 1)]
    assert_verdict judge(:link_down, ticks + carrier), :unsupported, /tick stopped for 1\.\d+ s/
  end

  def test_a_refused_command_is_unsupported_with_qemus_answer
    refusal = Probe::Refusal.new(kind: :chardev_stop, answer: 'QEMU refused chardev-change: GenericError: busy', leaves_state: false)
    verdict = Probe.judge(refusal, [], expected_crc: CRC)
    assert_equal ['chardev_stop', :unsupported, refusal.answer], [verdict.kind.to_s, verdict.status, verdict.reason]
    assert_equal 'fault probe: chardev_stop unsupported: QEMU refused chardev-change: GenericError: busy', Probe.line(verdict)
  end

  def test_guest_lines_are_read_per_output_and_a_crc_is_always_hexadecimal
    assert_equal [12, 0x12345678], Probe.observe('fault: blk ok 12 12345678', output: :serial, at: 1.0).values
    assert_equal [0], Probe.observe('fault: carrier 0', output: :serial, at: 1.0).values
    assert_equal :console, Probe.observe('con 7', output: :console, at: 1.0).signal
    assert_nil Probe.observe('con 7', output: :serial, at: 1.0)
    assert_nil Probe.observe('fault: tick 1', output: :console, at: 1.0)
    assert_nil Probe.observe('[    0.08] Run /init as init process', output: :serial, at: 1.0)
  end

  # A Qmp client over one end of a socket pair, its peer answering each command with reply;
  # yields the client and answers the commands it sent.
  def with_qmp(reply)
    Dir.mktmpdir do |directory|
      ours, theirs = UNIXSocket.pair
      sent = []
      peer = Thread.new do
        while (line = theirs.gets)
          request = JSON.parse(line)
          sent << request
          theirs.write("#{JSON.generate(reply.merge('id' => request['id']))}\n")
        end
      end
      yield Erx::Qmp.new(ours, directory: directory, timeout: 2), directory
      ours.close
      peer.join
      theirs.close
      sent
    end
  end

  def test_the_fault_commands_send_what_their_names_say
    sent = with_qmp('return' => {}) do |qmp, directory|
      qmp.set_link('nic0', up: false)
      qmp.block_set_io_throttle('blk0', bps_rd: 1)
      qmp.chardev_change('con0')
      qmp.chardev_change('con0', unix_socket: File.join(directory, 'console.sock'))
    end
    assert_equal %w[set_link block_set_io_throttle chardev-change chardev-change], sent.map { |request| request['execute'] }
    assert_equal({ 'name' => 'nic0', 'up' => false }, sent[0]['arguments'])
    assert_equal [1, 0, 0, 0, 0, 0], sent[1]['arguments'].values_at(*%w[bps_rd bps bps_wr iops iops_rd iops_wr])
    assert_equal 'null', sent[2]['arguments']['backend']['type']
    assert_equal false, sent[3]['arguments']['backend']['data']['server']
  end

  def test_a_chardev_socket_outside_the_connections_directory_is_refused_before_sending
    sent = with_qmp('return' => {}) do |qmp, _directory|
      assert_raises(Erx::Qmp::ProtocolError) { qmp.chardev_change('con0', unix_socket: '/tmp/elsewhere.sock') }
      assert_raises(ArgumentError) { qmp.set_link('nic0', up: 'no') }
      assert_raises(ArgumentError) { qmp.block_set_io_throttle('blk0', bps_rd: -1) }
    end
    assert_empty sent
  end

  def test_qemus_refusal_reaches_the_message_escaped
    with_qmp('error' => { 'class' => 'GenericError', 'desc' => "busy\e[31m" }) do |qmp, _directory|
      error = assert_raises(Erx::Qmp::ProtocolError) { qmp.chardev_remove('con0') }
      refute_includes error.message, "\e"
    end
  end
end
