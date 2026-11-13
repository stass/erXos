# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsPipeTest < Minitest::Test
  include ChokepointsHelper

  NIF = 'otp/erts/emulator/nifs/erxos/erx_pipe_nif.c'

  # A pipe's pages are read through erx_shm_copy; a generated load accessor
  # of the reader page or the lock page is refused anywhere in liberx and
  # the NIF, except the write end's acquire load of rpos.
  def test_only_the_shared_page_copy_reads_a_pipes_pages
    accessor = [rule('pipe-pages-accessor')]
    allowed = {
      'liberx/erx_pipe_core.c' => "erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_CUR, &cur, sizeof(cur));\n" \
                                  "(void)erx_pipe_rpage_rpos_load(rpage, &rpos);\n" \
                                  "(void)erx_pipe_lock_owner_store(lock, 0);\n",
      'include/erx/abi.h' => "erx_pipe_lock_cur_load(const erx_pipe_lock_t *record, uint32_t *value)\n",
      NIF => "(void)erx_pipe_rpage_rpos_load(rpage, &rpos);\n"
    }
    assert_empty evaluate(accessor, allowed, imported: [NIF])
    found = evaluate(accessor, { 'liberx/erx_pipe_core.c' => "uint32_t cur;\n(void)erx_pipe_lock_cur_load(lock, &cur);\n" })
    assert_equal ['pipe-pages-accessor: liberx/erx_pipe_core.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    refute_empty evaluate(accessor, { 'liberx/program/fd.c' => "erx_pipe_rpage_wake_load(p, &w);\n" })
    refute_empty evaluate(accessor, { NIF => "erx_pipe_lock_waiters_load(l, &w);\n" }, imported: [NIF])

    raw = [rule('pipe-pages-raw-load')]
    refute_empty evaluate(raw, { 'liberx/erx_pipe_check.c' => "x = atomic_load_explicit(p, memory_order_relaxed);\n" })
    refute_empty evaluate(raw, { 'liberx/program/pipe.c' => "x = __atomic_load_n(p, __ATOMIC_ACQUIRE);\n" })
    refute_empty evaluate(raw, { 'include/erx/pipe.h' => "return (atomic_load(p));\n" })
    # The one copy lives outside the pipe's files, and other liberx files keep their own loads.
    assert_empty evaluate(raw, { 'include/erx/shm.h' => "word = atomic_load_explicit(&area[i], memory_order_relaxed);\n",
                                 'liberx/erx_lane.c' => "x = atomic_load_explicit(p, memory_order_acquire);\n" })
  end

  # docs/design-pipes.md, Verification, build checks of the hand-offs: the
  # rule refuses its seed and admits the driver, the NIF and its header.
  def test_only_the_program_driver_takes_a_hand_off
    take = [rule('pipe-hand-take')]
    gate = 'otp/erts/emulator/sys/erxos/erx_gate.c'
    driver = 'otp/erts/emulator/sys/erxos/erx_program_drv.c'
    refute_empty evaluate(take, { gate => "\thand = erx_pipe_hand_take(number, program, owner);\n" }, imported: [gate])
    refute_empty evaluate(take, { gate => "\terx_pipe_holder_release(program);\n" }, imported: [gate])
    assert_empty evaluate(take, { driver => "\thand = erx_pipe_hand_take(number, program, owner);\n" \
                                            "\terx_pipe_holder_release(program);\n",
                                  NIF => "erx_pipe_hand_take(uint64_t number, uint64_t program, ERL_NIF_TERM caller)\n" },
                          imported: [driver, NIF])
  end

  # The C half of pipe-holder-gone: the NIF alone names the atom it sends; the seed
  # is the program driver sending it.
  def test_only_the_pipe_nif_says_a_program_is_gone
    gone = [rule('pipe-holder-gone')]
    driver = 'otp/erts/emulator/sys/erxos/erx_program_drv.c'
    refute_empty evaluate(gone, { driver => "\tatom = driver_mk_atom(\"erx_pipe_holder_gone\");\n" }, imported: [driver])
    refute_empty evaluate(gone, { 'liberx/program/pipe.c' => "#define GONE \"erx_pipe_holder_gone\"\n" })
    assert_empty evaluate(gone, { NIF => "\tatom_holder_gone = enif_make_atom(env, \"erx_pipe_holder_gone\");\n" },
                          imported: [NIF])
  end

  # A pipe lane is the lane layout: the pipe's files name its ring header and record, and
  # wpos's acquire load, but not the reader page or control table of a connection lane;
  # any other file outside the lane reader still names none of them.
  def test_the_pipes_files_share_the_lanes_ring_header_and_record
    lane = [rule('lane-pages-reader')]
    assert_empty evaluate(lane, { 'liberx/erx_pipe_check.c' => "_Static_assert(ERX_LANE_REC_SIZE == 16, \"x\");\n",
                                  'liberx/program/pipe.c' => "(void)erx_lane_hdr_wpos_load(hdr, &wpos);\n" \
                                                           "erx_shm_copy(a, s, p, &rec, ERX_LANE_REC_SIZE);\n",
                                  NIF => "erx_lane_rec_t rec;\nn = ERX_LANE_HDR_OFF_WPOS;\n" },
                          imported: [NIF])
    refute_empty evaluate(lane, { 'liberx/erx_pipe_core.c' => "(void)erx_lane_rpage_rpos_load(r, &rpos);\n" })
    refute_empty evaluate(lane, { 'liberx/program/pipe.c' => "const erx_lane_ctl_t *c;\n" })
    refute_empty evaluate(lane, { 'liberx/erx_pipe_core.c' => "data = side + ERX_LANE_SIDE_DATA;\n" })
    refute_empty evaluate(lane, { 'liberx/erx_pipe_core.c' => "n = ERX_LANE_CTL_SIZE;\n" })
    refute_empty evaluate(lane, { 'include/erx/pipe.h' => "off = ERX_LANE_RPAGE_OFF_RPOS;\n" })
    refute_empty evaluate(lane, { 'liberx/program/fd.c' => "erx_lane_rec_t rec;\n" })
    refute_empty evaluate(lane, { 'otp/erts/emulator/nifs/erxos/erx_device_nif.c' => "x = ERX_LANE_HDR_OFF_WPOS;\n" },
                          imported: ['otp/erts/emulator/nifs/erxos/erx_device_nif.c'])

    accessor = [rule('pipe-pages-accessor')]
    assert_empty evaluate(accessor, { 'liberx/erx_pipe_core.c' => "(void)erx_lane_hdr_wpos_load(hdr, &wpos);\n",
                                      'liberx/erx_lane.c' => "erx_lane_hdr_need_load(h, &need);\n" })
    refute_empty evaluate(accessor, { 'liberx/program/pipe.c' => "(void)erx_lane_hdr_need_load(hdr, &need);\n" })
    # The lane reader loads a lane's header, never a pipe's reader page or lock page.
    refute_empty evaluate(accessor, { 'liberx/erx_lane.c' => "erx_pipe_lock_waiters_load(l, &w);\n" })
  end

  # The pipe's files never name the frame kind; the lane reader and the funnel do.
  def test_no_pipe_step_names_the_frame_kind
    frame = [rule('pipe-no-frame-record')]
    refute_empty evaluate(frame, { 'liberx/erx_pipe_check.c' => "case ERX_REC_FRAME:\n" })
    refute_empty evaluate(frame, { 'liberx/erx_pipe_core.c' => "if (k == ERX_REC_FRAME) return;\n" })
    refute_empty evaluate(frame, { NIF => "k = ERX_REC_FRAME;\n" }, imported: [NIF])
    refute_empty evaluate(frame, { 'liberx/program/pipe.c' => "if (rec.kind == ERX_REC_FRAME) return;\n" })
    assert_empty evaluate(frame, { 'liberx/erx_pipe_check.c' => "case ERX_REC_DATA:\ncase ERX_REC_CONTROL:\n",
                                   'liberx/erx_funnel.c' => "if (part.kind != ERX_REC_FRAME) return;\n" })
  end
end
