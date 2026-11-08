# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The lane's reader and writer, the one file that reaches a lane's
    # pages, and the names that reach them: the shared layouts of a lane's
    # ring header, reader page and record, their generated accessors, and
    # the offsets of a side's parts.
    LANE_READER = 'liberx/erx_lane.c'
    LANE_LAYOUT = /\b(?:erx_lane_(?:hdr|rpage|rec)\w*|ERX_LANE_(?:HDR|RPAGE|REC|SIDE)_\w*)/
    # The inherited runtimes and C library erXos edits in place, where a
    # second reader could otherwise hide: no upstream name starts erx_.
    INHERITED_RUNTIME = %w[otp/**/* musl/**/*].freeze
    # OTP's inherited C++ JIT assembler, which uses trigraph-like text the
    # C view refuses and has no place for a lane.
    ASMJIT = 'otp/erts/emulator/asmjit/**/*'
    # The ABI generator's outputs that define those names; its other C
    # outputs name none of them and are read like any other file.
    ABI_C_OUTPUTS = %w[include/erx/abi.h include/erx/abi_reader.h liberx/generated/abi_reader.c
                       fuzz/generated/abi.c].freeze
    # The host drivers that play the other party to the reader and the
    # writer in their tests; no build of a runtime links them.
    LANE_PRODUCERS = %w[test/fixtures/lane_driver.c tools/fuzz/lane_fuzz.c tools/fuzz/lane_writer_fuzz.c].freeze
    DOMAINS = 'docs/design-domains.md'

    declare_group(
      unchecked_objects: [LANE_READER],
      rules: [
        # D3: a runtime reads a lane's ring only through erx_lane_take, and
        # writes one and reads the peer's reader page only through
        # erx_lane_put. A file that cannot name the ring header, the record,
        # the reader page or where they sit in a side has no typed way to
        # reach them, so this text rule keeps every other typed reader and
        # writer out, the funnel's pure check and the lane port driver
        # included. It reads erXos's own C, the imports below kernel/
        # included, the stopgap kernel's tree with its glue, and inherited
        # OTP and musl. It cannot see untyped pointer arithmetic on a side's
        # address (the reader record's side pointers, or the mapping that
        # produced them), nor a name a macro pastes together
        # (erx_lane_ ## hdr): those residuals are in TODO.md, for the
        # syntax-tree leg and for the reader owning the mapping.
        Chokepoints::Forbidden.new(
          name: 'lane-pages-reader',
          rule: "only #{LANE_READER}, whose erx_lane_take and erx_lane_put are the one reader and the one " \
                "writer of a lane's ring, names a lane's shared layouts, their accessors or the offsets of a side (D3)",
          design: "#{DOMAINS}#the-funnel",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*', *INHERITED_RUNTIME], except: [ASMJIT]),
          pattern: LANE_LAYOUT,
          sites: [LANE_READER, *ABI_C_OUTPUTS, *LANE_PRODUCERS].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/erx_funnel.c' => "void f(void) { erx_lane_hdr_wpos_load(hdr, &wpos); }\n",
                  'otp/erts/emulator/sys/erxos/erl_lane_drv.c' => "const erx_lane_rec_t *rec = ring;\n",
                  'liberx/backend/hosted/peek.c' => "data = side + ERX_LANE_SIDE_DATA;\n",
                  'liberx/erx_lane_peek.c' => "#define RING struct erx_lane_hdr\n",
                  'liberx/erx_lane_port.c' => "erx_lane_hdr_wpos_store(hdr, pos);\n" }
        )
      ]
    )
  end
end
