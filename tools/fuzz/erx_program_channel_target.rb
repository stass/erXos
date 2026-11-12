# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# A program's channel as the erx_program driver reads it: records through the
# funnel's channel mode, the shape reader and the credit. Inputs in
# tools/fuzz/erx_program_channel_fuzz.c's format: a mode byte, then steps, each a
# reply byte (top bit set, the slot below) or a record (a byte, a 16-bit
# little-endian length, the bytes; a byte of 0x40 to 0x7f grants a notice). Seeds:
# requests on the first and last slots, a repeated request on a busy slot, a reply
# that frees it, another shape, a granted {closed} notice delivered and then
# repeated, a {drained} notice never granted, and
# requests holding a pid at the machine's host and a fun, which the host grammar
# refuses, to a receiver that is the system domain (mode bit 0x10) and to one
# with no host (0x20), whose grammar and host channel mode ignores.
atom = ->(name) { [119, name.bytesize].pack('CC') + name }
small = ->(value) { [97, value].pack('CC') }
tuple = ->(*elements) { [104, elements.size].pack('CC') + elements.join }
request = ->(slot) { "\x83".b + tuple.call(atom.call('erx_prog'), small.call(1), small.call(slot), atom.call('getpid')) }
pid = "\x58".b + atom.call('web@erxos') + [5, 0, 3].pack('NNN')
# NEW_FUN_EXT of m with no free variables: uniq, index, count, module, old index and uniq, creator.
fun = [112, 0, 0].pack('CNC') + ("\x01".b * 16) + [0, 0].pack('NN') + atom.call('m') +
      small.call(0) + small.call(0) + pid
holding = ->(term) { "\x83".b + tuple.call(atom.call('erx_prog'), small.call(1), small.call(0), term) }
step = ->(bytes) { "\x00".b + [bytes.bytesize].pack('v') + bytes }
reply = ->(slot) { (0x80 | slot).chr.b }
notice = ->(*key) { "\x83".b + tuple.call(atom.call('erx_prog'), small.call(1), tuple.call(*key)) }
# The fuzz harness's first grant, 0x40, is {closed, 1, 1} (grant_of).
closed = notice.call(atom.call('closed'), small.call(1), small.call(1))
drained = notice.call(atom.call('drained'), small.call(1), small.call(1), small.call(1))
Erx::PackFuzz.declare_target(
  sources: %w[liberx/erx_funnel.c liberx/erx_etf.c
              otp/erts/emulator/sys/erxos/erx_program_core.c
              kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c],
  includes: [*Erx::PackFuzz::INCLUDES, 'otp/erts/emulator/sys/erxos'],
  seeds: {
    'requests' => "\x0f".b + step.call(request.call(0)) + step.call(request.call(15)),
    'busy' => "\x0f".b + step.call(request.call(3)) + step.call(request.call(3)),
    'replied' => "\x0f".b + step.call(request.call(3)) + reply.call(3) + step.call(request.call(3)) + reply.call(9),
    'other' => "\x0f".b + step.call("\x83".b + tuple.call(atom.call('closed'), small.call(1))),
    'notice' => "\x0f\x40".b + step.call(closed) + step.call(closed),
    'undue' => "\x0f".b + step.call(drained),
    'pid' => "\x1f".b + step.call(holding.call(pid)),
    'fun' => "\x2f".b + step.call(holding.call(fun))
  }
)
