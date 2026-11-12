# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # liberx's program layer, the code a program runs before and around its
    # main (docs/design-programs.md#the-startup-message).
    declare_group(
      rules: [
        # The program layer sits above the kernel interface, as a service
        # does: the backend's task entry calls into it, and it reaches the
        # kernel only through liberx's erx_ calls, so erXos's own kernel
        # replaces the backend under it and nothing in it moves.
        Chokepoints::Forbidden.new(
          name: 'program-layer-above-the-backend',
          rule: "liberx's program layer (liberx/program/) names no erx_fiasco_ symbol",
          design: 'docs/design-programs.md#verification-and-testing',
          scope: Chokepoints::Scope.new(own: false, extra: ['liberx/program/**/*']),
          pattern: /\berx_fiasco_\w*/,
          seed: { 'liberx/program/seeded.c' => "void f(void) { erx_fiasco_libc_start(0); }\n" }
        ),
        # The layer runs before main and beside it, in a program whose heap
        # and standard I/O are the program's own: it takes whole pages from
        # the kernel interface and writes nothing through stdio, so a program
        # that replaces either finds the layer independent of it.
        Chokepoints::Forbidden.new(
          name: 'program-layer-no-malloc-or-stdio',
          rule: "liberx's program layer (liberx/program/) calls neither musl's malloc family nor its stdio",
          design: 'docs/design-programs.md#verification-and-testing',
          scope: Chokepoints::Scope.new(own: false, extra: ['liberx/program/**/*']),
          pattern: /\b(?:malloc|calloc|realloc|reallocarray|free|aligned_alloc|posix_memalign|strdup|strndup|
                      [fsv]?printf|v[fs]printf|snprintf|vsnprintf|dprintf|puts|fputs|putchar|fputc|putc|
                      fopen|fdopen|fclose|fwrite|fread|fflush|perror|getchar|fgets)\s*\(|<stdio\.h>/x,
          seed: { 'liberx/program/seeded.c' => "void *f(void) { return (malloc(16)); }\n" }
        ),
        # The outbound lane has one writer, the channel's send, which writes each frame
        # whole under its one lock, so the frames of two workers never interleave and a
        # request is an obligation from its send on. A second writer in the layer, or in a
        # program the programs suite runs, would keep a writer state of its own over the
        # same ring. note.c alone writes raw: its burst case writes records without ringing
        # the session, which the send would do, and it calls no send of liberx's. The rule
        # reads only the layer and the suite's programs: elsewhere in liberx a lane put is
        # another lane's, and only the program layer maps a program's channel.
        Chokepoints::Forbidden.new(
          name: 'program-channel-send',
          rule: "only liberx/program/channel.c, the channel's send, readies a lane writer or puts into a " \
                "lane in liberx's program layer (liberx/program/) and the programs suite's programs " \
                '(test/guest/programs/), where test/guest/programs/note.c writes its own records raw',
          design: 'docs/design-programs.md#signals-in-liberx',
          scope: Chokepoints::Scope.new(own: false, extra: ['liberx/program/**/*', 'test/guest/programs/**/*']),
          pattern: /\berx_lane_(?:put|put_armed|writer_init)\s*\(/,
          sites: [Chokepoints::Site.new(glob: 'liberx/program/channel.c'),
                  Chokepoints::Site.new(glob: 'test/guest/programs/note.c')],
          seed: { 'liberx/program/seeded.c' => "void f(void) { (void)erx_lane_put(&writer, &item, &put); }\n",
                  'test/guest/programs/seeded.c' => "bool f(void) { return (erx_lane_writer_init(&w, own, peer, n)); }\n" }
        )
      ],
      unchecked_objects: %w[liberx/program/program.c liberx/program/program.h liberx/program/channel.c
                            liberx/program/channel.h liberx/program/startup.c
                            liberx/program/startup.h liberx/program/inbound.c liberx/program/inbound.h
                            liberx/program/pages.c liberx/program/pages.h liberx/program/fd.c
                            liberx/program/fd.h liberx/program/pipe.c liberx/program/pipe.h]
    )
  end
end
