# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/hostlink_frame'

# Writes test/fixtures/hostlink_frames.txt, the host link's shared frame vectors, which
# test/host/hostlink_frame_test.rb checks the Ruby frame layer against and
# test/erlang/erx_hostlink_frame_tests.erl the Erlang one:
#   ruby test/fixtures/hostlink_vectors.rb > test/fixtures/hostlink_frames.txt
# A vector is one line of words. `cobs NAME DECODED ENCODED` is a COBS encoding both
# ways; `cobs_bad NAME ENCODED` fails to decode; `crc NAME DATA CRC` is CRC-32C's value
# in hex; `feed NAME SIDE RESULTS BYTES` is what a fresh deframer of SIDE gives for BYTES
# fed at once, RESULTS being `none` or results joined by `,`, each `discard:REASON` or
# `frame:STREAM:SESSION:SEQ:TARGET:BODY`. Byte strings are lowercase hex, `-` for none.
# The COBS encodings are the examples of Wikipedia's "Consistent Overhead Byte Stuffing"
# article and the CRC values RFC 3720's and the CRC catalogue's check value, written out
# here, not computed; the frames are built field by field, apart from HostlinkFrame.encode.
module HostlinkVectors
  F = Erx::HostlinkFrame
  SESSION = (0..15).to_a.pack('C*').freeze
  RUN = (1..254).to_a.pack('C*').freeze

  module_function

  def hex(bytes) = bytes.empty? ? '-' : bytes.unpack1('H*')

  # A frame's wire bytes from its fields, with the CRC given or computed.
  def wire(stream:, body:, seq: 0, target: 0, version: F::VERSION, reserved: 0, session: SESSION, crc: nil)
    header = [version, stream, reserved].pack('CCv') + session + [seq, target].pack('VV')
    covered = header + body
    "#{F.cobs_encode(covered + [crc || F.crc32c(covered)].pack('V'))}\0".b
  end

  def control_body(kind:, total:, id:, piece:, more: false)
    [kind, more ? 1 : 0, 0, total, id].pack('CCvVQ<') + piece
  end

  def frame_result(stream, body, seq: 0, target: 0, session: SESSION)
    "frame:#{stream}:#{hex(session)}:#{seq}:#{target}:#{hex(body)}"
  end

  def cobs_vectors
    [['empty', '', '01'], ['zero', '00', '0101'], ['two_zeros', '0000', '010101'],
     ['zero_inside', '11220033', '0311220233'], ['no_zero', '11223344', '0511223344'],
     ['trailing_zeros', '11000000', '0211010101'],
     ['run_254', hex(RUN), "ff#{hex(RUN)}"], ['zero_then_run_254', "00#{hex(RUN)}", "01ff#{hex(RUN)}"],
     ['run_255', hex(RUN + "\xff".b), "ff#{hex(RUN)}02ff"],
     ['run_254_then_zero', hex((2..255).to_a.pack('C*') + "\0"), "ff#{hex((2..255).to_a.pack('C*'))}0101"],
     ['run_253_zero_one', hex((3..255).to_a.pack('C*') + "\0\x01".b), "fe#{hex((3..255).to_a.pack('C*'))}0201"]]
      .map { |name, decoded, encoded| "cobs #{name} #{decoded.empty? ? '-' : decoded} #{encoded}" }
  end

  def cobs_bad_vectors
    [%w[overrun 051122], %w[overrun_last 02], %w[overrun_full ff01], %w[zero_code 0300]]
      .map { |name, encoded| "cobs_bad #{name} #{encoded}" }
  end

  def crc_vectors
    [['check', hex('123456789'), 'e3069283'], ['zeros_32', hex("\0" * 32), '8a9136aa'],
     ['ones_32', hex("\xff".b * 32), '62a8ab43'], ['incrementing_32', hex((0..31).to_a.pack('C*')), '46dd794e']]
      .map { |name, data, crc| "crc #{name} #{data} #{crc}" }
  end

  def feed_vectors
    terminal = wire(stream: 1, body: "ls\n".b)
    call_body = control_body(kind: 1, total: 5, id: 1, piece: "\x83\x64\x00\x01\x61".b)
    files_body = (0...F::BODY_MAX).map { |index| index % 251 }.pack('C*')
    two = wire(stream: 1, body: 'a'.b, seq: 1) + wire(stream: 4, body: "\0\0".b, seq: 2)
    corrupt = terminal.dup.tap { |bytes| bytes.setbyte(10, bytes.getbyte(10) ^ 0x40) }
    [['terminal', :target, frame_result('terminal', "ls\n".b), terminal],
     ['control_call', :target, frame_result('control', call_body, target: 3),
      wire(stream: 0, body: call_body, target: 3)],
     ['hello_session_zero', :target, frame_result('control', call_body, session: "\0" * 16),
      wire(stream: 0, body: call_body, session: "\0".b * 16)],
     ['files_largest_body', :target, frame_result('files', files_body, seq: 7), wire(stream: 4, body: files_body, seq: 7)],
     ['empty_body', :target, frame_result('terminal', ''.b, seq: 4_294_967_295),
      wire(stream: 1, body: ''.b, seq: 4_294_967_295)],
     ['leading_zero', :target, frame_result('terminal', "ls\n".b), "\0#{terminal}"],
     ['two_frames', :target, "#{frame_result('terminal', 'a', seq: 1)},#{frame_result('files', "\0\0", seq: 2)}", two],
     ['empty_frames_only', :target, 'none', "\0\0\0"],
     ['truncated_no_zero', :target, 'none', terminal.byteslice(0...-1)],
     ['truncated_then_zero', :target, 'discard:cobs', "#{terminal.byteslice(0, 12)}\0"],
     ['crc_flipped', :target, 'discard:crc', corrupt],
     ['crc_wrong', :target, 'discard:crc', wire(stream: 1, body: 'x'.b, crc: 0)],
     ['short_header', :target, 'discard:short', "#{F.cobs_encode("\x02\x01".b + ("\x05" * 29))}\0"],
     ['body_over_max', :target, 'discard:oversize', wire(stream: 4, body: "\x01".b * (F::BODY_MAX + 1))],
     ['encoded_at_bound', :target, 'discard:cobs', "#{"\xff".b * F::ENCODED_MAX}\0"],
     ['encoded_over_bound', :target, 'discard:oversize', "#{"\xff".b * (F::ENCODED_MAX + 1)}\0"],
     ['oversize_then_frame', :target, "discard:oversize,#{frame_result('terminal', "ls\n".b)}",
      "#{"\x01".b * 9000}\0#{terminal}"],
     ['bad_cobs', :target, 'discard:cobs', "\x05\x11\x22\0".b],
     ['version_1', :target, 'discard:version', wire(stream: 1, body: 'x'.b, version: 1)],
     ['reserved_set', :target, 'discard:header', wire(stream: 1, body: 'x'.b, reserved: 1)],
     ['target_on_terminal', :target, 'discard:header', wire(stream: 1, body: 'x'.b, target: 1)],
     ['unknown_stream', :host, 'discard:stream', wire(stream: 5, body: 'x'.b)],
     ['events_at_target', :target, 'discard:stream', wire(stream: 2, body: 'log'.b)],
     ['events_at_host', :host, frame_result('events', 'log'), wire(stream: 2, body: 'log'.b)],
     ['credit_at_target', :target, 'discard:stream', wire(stream: 3, body: ''.b, target: 4096)],
     ['credit_at_host', :host, frame_result('credit', '', target: 4096), wire(stream: 3, body: ''.b, target: 4096)]]
      .map { |name, side, results, bytes| "feed #{name} #{side} #{results} #{hex(bytes.b)}" }
  end

  def lines = [*cobs_vectors, *cobs_bad_vectors, *crc_vectors, *feed_vectors]
end

if $PROGRAM_NAME == __FILE__
  puts '# The host link frame vectors; see test/fixtures/hostlink_vectors.rb, which writes them.'
  puts HostlinkVectors.lines
end
