# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# liberx's funnel grammar over hostile frames. Inputs in
# tools/fuzz/erx_funnel_fuzz.c's format: a mode byte, a cut byte, then a
# frame body (header, control term, payload) or a bare control term or
# payload: a frame of every operation, held with every right and with
# none, the spawn request with options of every shape, and a payload with a
# repeated map key.
atom = ->(name) { [119, name.bytesize].pack('CC') + name }
# The harness's lane runs from web@erxos, domain 3, to system@erxos, domain 1.
pid = ->(node, id, creation) { "\x58".b + atom.call(node) + [id, 0, creation].pack('NNN') }
reference = ->(node, creation) { "\x5a\x00\x04".b + atom.call(node) + [creation, 1, 2, 3, 4].pack('N5') }
ref = reference.call('system@erxos', 1)
sender_ref = reference.call('web@erxos', 3)
tuple = ->(*elements) { [104, elements.size].pack('CC') + elements.join }
small = ->(value) { [97, value].pack('CC') }
from = pid.call('web@erxos', 5, 3)
to = pid.call('system@erxos', 9, 1)
options = [108, 3].pack('CN') + atom.call('link') + tuple.call(atom.call('priority'), atom.call('high')) +
          tuple.call(atom.call('max_heap_size'), [116, 1].pack('CN') + atom.call('size') + small.call(100)) + "\x6a"
controls = {
  'link' => [tuple.call(small.call(1), from, to), false],
  'monitor' => [tuple.call(small.call(19), from, to, sender_ref), false],
  'exit2' => [tuple.call(small.call(26), from, to), true],
  'send' => [tuple.call(small.call(22), from, to), true],
  'alias-send' => [tuple.call(small.call(33), from, ref), true],
  'spawn-request' => [tuple.call(small.call(29), sender_ref, from, to,
                                 tuple.call(atom.call('m'), atom.call('f'), small.call(1)), options), true],
  'spawn-reply' => [tuple.call(small.call(31), ref, to, small.call(0), from), false],
  'unlink' => [tuple.call(small.call(35), [110, 8, 0, *([0xff] * 8)].pack('C*'), from, to), false]
}
payload = "\x83".b + [108, 1].pack('CN') + atom.call('hello') + "\x6a"
frame = lambda do |control, with_payload|
  ctl = "\x83".b + control
  body = with_payload ? payload : ''.b
  [ctl.bytesize, body.bytesize].pack('VV') + ctl + body
end
# The cut byte 0x1f gives the frame's sender every right, 0x00 none.
seeds = controls.flat_map do |name, (control, with_payload)|
  body = frame.call(control, with_payload)
  [["frame-#{name}", "\x00\x1f".b + body], ["frame-#{name}-unheld", "\x00\x00".b + body]]
end.to_h
Erx::PackFuzz.declare_target(
  sources: %w[liberx/erx_funnel.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c],
  seeds: seeds.merge(
    'control-spawn' => "\x05\x00".b + "\x83".b + controls.fetch('spawn-request').first,
    'payload-key' => "\x3e\x00".b + "\x83".b + [116, 2, 97, 1, 106].pack('CNCCC') + [110, 1, 0, 1, 106].pack('C*'),
    'payload-system' => "\x7e\x00".b + payload
  )
)
