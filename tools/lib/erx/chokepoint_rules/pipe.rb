# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The pipe's checks of what its ends copy from shared pages, and its
    # writer's and reader's steps.
    PIPE_CHECK = 'liberx/erx_pipe_check.c'
    PIPE_CORE = 'liberx/erx_pipe_core.c'
    # The runner that performs the core's steps on an end's mapped pages.
    PIPE_RUN = 'liberx/erx_pipe_run.c'
    # The generated accessors that load a field of a page a pipe lane or
    # lock uses: its reader page, lock page and ring header. The published
    # positions' acquire loads are the exception: a write end's of rpos and
    # a read end's of wpos. The lane's own reader and writer load the ring
    # header of every other lane.
    PIPE_PAGE_LOAD = /\b(?:erx_pipe_(?:rpage|lock)|erx_lane_hdr)_\w+_load\b/
    PIPE_PUBLISHED_LOAD = /\A(?:erx_pipe_rpage_rpos|erx_lane_hdr_wpos)_load\z/
    # A load the C language or the compiler offers, which a pipe file makes
    # only through erx_shm_copy (include/erx/shm.h).
    RAW_ATOMIC_LOAD = /\b(?:atomic_load(?:_explicit)?|__atomic_load(?:_n)?|__c11_atomic_load)\b/
    PIPES = 'docs/design-pipes.md'
    # The pipe NIF's entries for the program driver, and the driver.
    PIPE_HAND_HEADER = 'otp/erts/emulator/nifs/erxos/erx_pipe.h'
    PIPE_HAND_DRIVER = 'otp/erts/emulator/sys/erxos/erx_program_drv.c'

    declare_group(
      unchecked_objects: [PIPE_CHECK, PIPE_CORE, PIPE_RUN],
      rules: [
        # Only erx_shm_copy reads a pipe's shared pages, apart from the one
        # acquire load of each published position (docs/design.md,
        # "Chokepoint checks"). Over liberx and the NIF, no file loads a
        # field of a pipe's reader page, lock page or ring header through its
        # generated accessor but the published positions', rpos's and wpos's,
        # each loaded with acquire order; over the pipe's own files, no file
        # makes an atomic load of
        # its own. Untyped pointer arithmetic with a plain dereference or a
        # memcpy from a page escapes these text rules (TODO.md, the pipe's
        # shared-page chokepoint).
        Chokepoints::Forbidden.new(
          name: 'pipe-pages-accessor',
          rule: "only erx_shm_copy reads a pipe's shared pages: in liberx and #{PIPE_NIF}, no generated accessor " \
                "loads a field of a pipe's reader page, lock page or ring header but erx_pipe_rpage_rpos_load and " \
                "erx_lane_hdr_wpos_load, the published positions' acquire loads; erx_lane.c loads every other lane's header",
          design: "#{PIPES}#the-ring",
          scope: Chokepoints::Scope.new(own: false, extra: ['liberx/**/*', 'include/erx/**/*', PIPE_NIF]),
          pattern: PIPE_PAGE_LOAD,
          sites: ABI_C_OUTPUTS.map { |path| Chokepoints::Site.new(glob: path) } +
                 [Chokepoints::Site.new(glob: LANE_READER, permits: /\Aerx_lane_hdr_\w+_load\z/)] +
                 ['liberx/**/*', 'include/erx/**/*', PIPE_NIF].map do |glob|
                   Chokepoints::Site.new(glob: glob, permits: PIPE_PUBLISHED_LOAD)
                 end,
          seed: { 'liberx/erx_pipe_core.c' => "erx_pipe_lock_cur_load(lock, &cur);\n",
                  'liberx/program/pipe.c' => "(void)erx_pipe_rpage_sleepers_load(rpage, &sleepers);\n",
                  PIPE_NIF => "erx_pipe_lock_owner_load(page, &owner);\n",
                  'liberx/erx_pipe_check.c' => "(void)erx_lane_hdr_need_load(hdr, &need);\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'pipe-pages-raw-load',
          rule: "only erx_shm_copy reads a pipe's shared pages: the pipe's files (#{PIPE_FILES.join(', ')}) " \
                'make no atomic load of their own',
          design: "#{PIPES}#the-ring",
          scope: Chokepoints::Scope.new(own: false, extra: PIPE_FILES),
          pattern: RAW_ATOMIC_LOAD,
          seed: { PIPE_CHECK => "owner = atomic_load_explicit(&lock->owner, memory_order_relaxed);\n",
                  'liberx/program/pipe.c' => "w = __atomic_load_n(&hdr[0], __ATOMIC_ACQUIRE);\n",
                  PIPE_NIF => "x = atomic_load(word);\n" }
        ),
        # No pipe step sees a frame record (docs/design.md, "Chokepoint
        # checks"): erx_ring_check accepts only the pipe's record kinds, which
        # test/host/pipe_check_test.rb checks with the frame kind admitted as
        # its seeded fault, and the pipe's files, which the lane group lets
        # name a lane's ring header and record, never name the kind a
        # connection's and a program channel's lanes carry.
        Chokepoints::Forbidden.new(
          name: 'pipe-no-frame-record',
          rule: "no pipe step sees a frame record: the pipe's files (#{PIPE_FILES.join(', ')}), those of " \
                'erx_ring_check, erx_pipe_wstep, erx_pipe_rstep, the pipe ends and the pipe NIF, never name ERX_REC_FRAME',
          design: "#{PIPES}#the-ring",
          scope: Chokepoints::Scope.new(own: false, extra: PIPE_FILES),
          pattern: /\bERX_REC_FRAME\b/,
          seed: { PIPE_CHECK => "case ERX_REC_FRAME:\n",
                  'liberx/erx_pipe_core.c' => "if (copy.kind == ERX_REC_FRAME)\n",
                  PIPE_NIF => "kind = ERX_REC_FRAME;\n" }
        ),
        # Only the pipe server makes a pipe's objects (PI1) and the hand-offs
        # that give them to programs; only a program's handler makes and
        # drops the holder entry it speaks for its program by; only the pipe
        # server hears a program's gone. The Erlang sources are PipeCallers'.
        Chokepoints::Elsewhere.new(
          name: 'pipe-makers', rule: "only the session's pipe server, erx_pipe_srv, calls erx_pipe_nif's make_lock/1, " \
                                     'make_lane/1, make_bell/3 and hand_make/2, which make a pipe\'s lock, lanes and ' \
                                     'bells and the hand-offs that give them to programs',
          design: "#{PIPES}#invariants", check: 'PipeCallers, in Checks', test: 'test/host/pipe_callers_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'pipe-holders', rule: "only a program's handler, erx_prog_handler, calls erx_pipe_nif's " \
                                      'program_holder/1 and holder_drop/1, which make and let go the holder entry ' \
                                      'by which it speaks for its program',
          design: "#{PIPES}#hand-offs", check: 'PipeCallers, in Checks', test: 'test/host/pipe_callers_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'pipe-holder-gone-erlang', rule: 'only erx_pipe_srv, which receives it, names the atom ' \
                                                 "erx_pipe_holder_gone, a program's gone, among the Erlang sources",
          design: "#{PIPES}#hand-offs", check: 'PipeCallers, in Checks', test: 'test/host/pipe_callers_test.rb'
        ),
        # The driver alone takes a hand-off and lets the port's hold on a
        # holder entry go; the NIF defines both and its header declares them.
        Chokepoints::Forbidden.new(
          name: 'pipe-hand-take',
          rule: "only #{PIPE_HAND_DRIVER} calls erx_pipe_hand_take and erx_pipe_holder_release in ERTS",
          design: "#{PIPES}#hand-offs",
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_pipe_(?:hand_take|holder_release)\s*\(/,
          sites: [PIPE_HAND_DRIVER, PIPE_NIF, PIPE_HAND_HEADER].map { |glob| Chokepoints::Site.new(glob: glob) },
          seed: { 'otp/erts/emulator/sys/erxos/erx_gate.c' => "\thand = erx_pipe_hand_take(number, program, owner);\n" }
        ),
        # The NIF alone says a program is gone: no C file of ERTS or liberx
        # names the atom erx_pipe_holder_gone but erx_pipe_nif.c, which sends
        # it once neither hold of a holder entry remains.
        Chokepoints::Forbidden.new(
          name: 'pipe-holder-gone',
          rule: "only #{PIPE_NIF} sends erx_pipe_holder_gone, a program's gone: no other C file names the atom",
          design: "#{PIPES}#hand-offs",
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/**/* liberx/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_pipe_holder_gone\b/,
          sites: [Chokepoints::Site.new(glob: PIPE_NIF)],
          seed: { PIPE_HAND_DRIVER => "\tatom = driver_mk_atom(\"erx_pipe_holder_gone\");\n" }
        )
      ]
    )
  end
end
