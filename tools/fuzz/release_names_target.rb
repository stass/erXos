# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# erx_release_fs_add_name, the release NIFs' decoder of name lists, in
# tools/fuzz/release_names_fuzz.c's format: names, each a 16-bit length and
# its bytes. The seeds are short lists, each kind of refused name, and lists
# on each side of the design's limits: 255 bytes a name, 256 names, and a
# NUL's room in a list's 4,096 bytes.
names = ->(list) { list.map { |name| [name.bytesize].pack('v') + name.b }.join.b }
long = ['n' * 255] * 15
Erx::PackFuzz.declare_target(
  sources: ['liberx/release_fs.c'],
  seeds: {
    'empty' => ''.b,
    'one' => names.call(['a']),
    'nested' => names.call(%w[d e i]),
    'refused' => names.call(['', '.', '..', 'a/b', "a\0b", "\xC0\xAF", "\xED\xA0\x80", "\xF4\x90\x80\x80", 'x']),
    'utf8' => names.call(["\xE2\x82\xAC", "\xF4\x8F\xBF\xBF", '...']),
    'longest-name' => names.call(['z' * 255]),
    'name-too-long' => names.call(['z' * 256]),
    'most-names' => names.call(['z'] * 256),
    'too-many-names' => names.call(['z'] * 257),
    'fills-the-room' => names.call([*long, 'n' * 253, 'n']),
    'past-the-room' => names.call([*long, 'n' * 254, 'n']),
    'cut-short' => names.call(['a']) + [10].pack('v') + 'abc'.b
  }
)
