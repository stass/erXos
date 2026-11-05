# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# erx_ns_resolve and the release file system's core. The seeds start mutation on
# both sides of each limit: a name of 255 and 256 bytes, 256 and 257 names, `..` at
# the top, a NUL, bad UTF-8, a narrowed namespace, and a release's table with a
# directory beside a name that sorts around it, and changes to the table: a server
# mount, binds of it, an unmount, the refusals at `/`, and a bind of the empty root.
long_name = 'n' * 256
many_names = (['n'] * 257).join('/')
long = ->(total) { ("/#{'n' * 200}" * ((total / 201) + 1)).byteslice(0, total) }
Erx::PackFuzz.declare_target(
  sources: ['liberx/ns.c', 'liberx/release_fs.c'],
  seeds: Erx::PackFuzz.indexed_seeds([
    "\x04/a/b\na/d/x\na/e\nd-x\nd/g\nd/h/i\nd0",
    "\x04/d/../d/h/./i/\na/d/x\nd-x\nd/g\nd/h/i\nd0",
    "\x04#{long_name[1..]}\nf",
    "\x04#{long_name}\nf",
    "\x04#{many_names[2..]}\nf",
    "\x04#{many_names}\nf",
    "\x04../../..\nf",
    "\x04a\x00b\nf",
    "\x04a\xc0\xafb\nf",
    "\x01/data\n/data/x\ndata/x",
    "\x02/data\n/data/logs\n/\nf",
    "\x09/data\n/data/x\nunder/x",
    "\x04\nf",
    "\x04#{long.call(4095)}\nf",
    "\x04#{long.call(4096)}\nf",
    "\x04#{long.call(4097)}\nf",
    "\x0d/a\n/a#{long.call(4091)}\nf",
    "\x24m/tmp\n/tmp/a\nf",
    "\x64m/tmp\nb/tmp/a\t/x\n/x/b\nf",
    "\xa4m/tmp\nB/tmp\t/y\nu/tmp\n/y/z\nf",
    "\xe4u/\nm/\nb/d\t/d\nu/./\n/d\nf",
    "\x21/data\nb/\t/x\n/x\nf",
    "\x64m/a\nb/a/#{long_name[1..]}\t/b\n/b\nf"
  ].map(&:b))
)
