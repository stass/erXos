# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The generated reader of ui.txt's binary form that a native renderer links
# (docs/design-abi.md, "Widget format"). Seeds: a stream of an insert with a
# status text, a list and an enum, a set with removals, a move, a commit, a
# screen and each input form; an insert cut short; and a pixels report, which
# a renderer refuses.
record = ->(body) { [body.bytesize].pack('V') + body }
text = ->(bytes) { [bytes.bytesize].pack('V') + bytes }
status_text = [11, 0, 0, 0, 0].pack('CCCCV') + text.call('hello')
list = [18].pack('C') + [2].pack('v') + text.call('one') + text.call("tw\xc3\xb6".b)
insert = record.call([1, 5, 0, 0, 11, 4].pack('CVVvCC') + [2].pack('C') + [100].pack('V') + [6, 3].pack('CC') +
                     status_text + list)
set = record.call([3, 5, 1, 17].pack('CVCC') + [-7].pack('l<') + [2, 11, 2].pack('CCC'))
inputs = [[1, 10, 20, 1].pack('CvvC'), [2, 1, 30].pack('CCv') + [0x41].pack('V'), [3, 0xff].pack('CC')]
stream = insert + set + record.call([4, 5, 1].pack('CVv')) + record.call([5].pack('C')) +
         record.call([7, 640, 480, 0x68081828].pack('CvvV')) + inputs.map { |body| record.call([8].pack('C') + body) }.join +
         record.call([9].pack('C'))

Erx::PackFuzz.declare_target(
  sources: ['build/gen/display/generated/erx_ui_wire.c'],
  seeds: {
    'stream' => stream,
    'insert-cut' => insert[0, insert.bytesize - 3],
    'pixels' => record.call([10, 0, 0, 1, 1].pack('Cvvvv') + "\0\0\0\0")
  }
)
