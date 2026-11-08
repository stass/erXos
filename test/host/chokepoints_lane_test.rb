# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsLaneTest < Minitest::Test
  include ChokepointsHelper

  # The reader and writer and the ABI's own outputs name the lane's
  # layouts; a second reader or writer anywhere else in erXos C, the
  # stopgap kernel or ERTS's erXos layer is refused, while code that only
  # drives the reader or the writer through its interface is not.
  def test_only_the_lane_reader_reaches_a_lanes_pages
    lane = [rule('lane-pages-reader')]
    allowed = {
      Rules::LANE_READER => "erx_lane_hdr_wpos_load(lane_header(r), &wpos);\nerx_lane_rec_t rec;\n",
      'include/erx/abi.h' => "typedef struct erx_lane_hdr erx_lane_hdr_t;\n#define ERX_LANE_SIDE_DATA 8192\n",
      'test/fixtures/lane_driver.c' => "erx_lane_rpage_rpos_load(rpage(), &rpos);\n",
      'liberx/erx_funnel.c' => "erx_lane_reader_t r;\nst = erx_lane_take(&r, buf, ERX_LANE_MAX, &part);\n" \
                               "if (part.kind != ERX_REC_FRAME || size < ERX_LANE_MIN) return;\n",
      'otp/erts/emulator/beam/dist.c' => "erx_lane_take(&r, buf, max, &part);\n",
      'otp/erts/emulator/sys/erxos/erl_lane_drv.c' => "erx_lane_writer_t w;\nerx_lane_item_t item;\n" \
                                                     "erx_lane_iov_t iov;\nst = erx_lane_put_armed(&w, &item, &put);\n"
    }
    assert_empty evaluate(lane, allowed, imported: ['otp/erts/emulator/beam/dist.c',
                                                    'otp/erts/emulator/sys/erxos/erl_lane_drv.c'])
    refute_empty evaluate(lane, { 'otp/erts/emulator/sys/erxos/erl_lane_drv.c' => "erx_lane_hdr_wpos_store(h, pos);\n" },
                          imported: ['otp/erts/emulator/sys/erxos/erl_lane_drv.c'])
    refute_empty evaluate(lane, { 'otp/erts/emulator/beam/dist.c' => "struct erx_lane_hdr *h;\n" },
                          imported: ['otp/erts/emulator/beam/dist.c'])
    refute_empty evaluate(lane, { 'musl/src/thread/x.c' => "x = ERX_LANE_REC_SIZE;\n" }, imported: ['musl/src/thread/x.c'])
    found = evaluate(lane, { 'liberx/erx_funnel.c' => "#include \"erx/abi.h\"\nuint64_t w = ERX_LANE_HDR_OFF_WPOS;\n" })
    assert_equal ['lane-pages-reader: liberx/erx_funnel.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    refute_empty evaluate(lane, { 'otp/erts/emulator/sys/erxos/erl_erxos_sys.c' => "erx_lane_rpage_t *p;\n" },
                          imported: ['otp/erts/emulator/sys/erxos/erl_erxos_sys.c'])
    refute_empty evaluate(lane, { 'fiasco/kernel/src/erx/lane.cpp' => "const erx_lane_rec_t *r;\n" })
    # The stopgap kernel's inherited sources are read as its glue is; the
    # inherited tree outside it, which no runtime links, and OTP's JIT
    # assembler are not.
    refute_empty evaluate(lane, { 'fiasco/kernel/src/kern/ipc.cpp' => "Mword w = ERX_LANE_HDR_OFF_WPOS;\n" },
                          imported: ['fiasco/kernel/src/kern/ipc.cpp'])
    assert_empty evaluate(lane, { 'fiasco/l4re-core/x.c' => "x = ERX_LANE_REC_SIZE;\n" },
                          imported: ['fiasco/l4re-core/x.c'])
    assert_empty evaluate(lane, { 'otp/erts/emulator/asmjit/x.cpp' => "x = ERX_LANE_REC_SIZE;\n" },
                          imported: ['otp/erts/emulator/asmjit/x.cpp'])
    # An import below kernel/ is read as erXos's own C (Checks#chokepoint_upstream?).
    refute_empty evaluate(lane, { 'kernel/crypto/blake3/x.c' => "x = ERX_LANE_REC_SIZE;\n" })
  end
end
