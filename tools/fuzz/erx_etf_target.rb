# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# liberx's erx_etf over hostile terms. Inputs in tools/fuzz/erx_etf_fuzz.c's
# format: a byte of rules (grammar, depth, words, accept, scratch), then a
# term: one of every kind of the grammar; a map with a key repeated in
# another encoding; a key that is a map; lists split across tails; deep
# nesting on the left and on the right; a pid off the host; and the terms
# that keep the most scratch per byte, with and without accept.
atom = ->(name) { [119, name.bytesize].pack('CC') + name }
pid = ->(node) { "\x58".b + atom.call(node) + [1, 2, 3].pack('NNN') }
every_kind = [104, 15].pack('CC') + [97, 5, 98, -7].pack('CCCl>') + [110, 9, 1, *([1] * 9)].pack('C*') +
             [70, 1.5].pack('CG') + atom.call('ok') + [109, 2, 0x61, 0x62].pack('CNCC') + [77, 1, 3, 0xe0].pack('CNCC') +
             [107, 2, 0x61, 0x62].pack('CnCC') + [108, 1, 97, 1, 107, 1, 2].pack('CNCCCnC') + pid.call('web@erxos') +
             [90, 4].pack('Cn') + atom.call('web@erxos') + [7, 1, 2, 3, 4].pack('N5') +
             [112, 0, 1].pack('CNC') + ("\x01" * 16) + [0, 1].pack('NN') + atom.call('m') + [97, 0, 97, 0].pack('C4') +
             pid.call('web@erxos') + "\x6a" + "\x71" + atom.call('m') + atom.call('f') + [97, 1].pack('CC') +
             [67, 1, 1].pack('CNC') + atom.call('m') + atom.call('r') + atom.call('a') + "\x6a" + [116, 0].pack('CN')
duplicate_key = [116, 2, 97, 1, 106].pack('CNCCC') + [110, 1, 0, 1, 106].pack('C*')
map_key = [116, 1].pack('CN') + [116, 2, 97, 1, 106, 97, 2, 106].pack('CNC*') + "\x6a"
tails = [108, 1, 97, 1, 108, 0, 108, 1, 97, 2, 107, 1, 3].pack('CNCCCNCNCCCnC')
right = ("\x68\x02\x6a" * 40) + "\x6a"
left = ("\x68\x02" * 40) + ("\x6a\x6a" * 40)
dense_keys = [116, 1, 116, 64].pack('CNCN') + ("\x6a" * 129)
dense_names = [67, 64, 1].pack('CNC') + atom.call('m') + atom.call('r') + (atom.call('') * 64)
Erx::PackFuzz.declare_target(
  sources: %w[liberx/erx_etf.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c],
  seeds: {
    'every-kind' => "\x7f\x83".b + every_kind, 'every-kind-system' => "\x7d\x83".b + every_kind,
    'every-kind-host' => "\x7e\x83".b + every_kind, 'duplicate-key' => "\x7c\x83".b + duplicate_key,
    'map-key' => "\x7c\x83".b + map_key, 'tails' => "\x7c\x83".b + tails, 'right' => "\x44\x83".b + right,
    'left' => "\x7c\x83".b + left, 'halved' => "\xfc\x83".b + map_key,
    'off-host' => "\x7c\x83".b + pid.call('web@elsewhere'), 'export-cut' => "\x7c\x83\x71".b,
    'dense-keys' => "\x7c\x83".b + dense_keys, 'dense-names' => "\x3c\x83".b + dense_names
  }
)
