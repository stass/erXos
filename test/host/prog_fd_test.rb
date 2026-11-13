# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/prog_profile_frames'

# A program's descriptor table and pipe ends (liberx/program/fd.h, liberx/program/pipe.h)
# through test/fixtures/prog_fd_driver.c, which fakes the backend over temporary files and
# checks every notice with the profile's generated check: a startup message's pipe
# descriptors become ends whose mappings carry bytes; dup shares an end and close empties a
# slot at once, the end going with its last reference, which sends {closed} exactly once
# and closes each capability once; a read end takes its index only through erx_pipe_rtake
# and ends its wait with a read of 0 bytes before it unmaps; and each report is applied to
# the end it names under the end's lock, or closes what it installed when no end is held.
# Calls through the table on real threads wait for the end's doorbell, which the driver's
# executor turns into erx_pipe_doorbell: two threads wait on one end, a call that clears
# what another waits on wakes it, a report wakes a waiting read, which then sends its
# {drained}, a poll's registrations on two ends all go when it wakes, and a thread that
# takes the table lock holding an end's stops (docs/design-pipes.md, "Ends in liberx" and
# "Ends and their holders"; docs/design-programs.md, "Descriptors and files" and "The event
# executor"). Every case runs under the address and undefined sanitizers, the threaded ones
# under the thread sanitizer too, and each seeded fault must fail the case named beside it.
class ProgFdTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  FD = 'liberx/program/fd.c'
  PIPE = 'liberx/program/pipe.c'
  SOURCES = [FD, PIPE, 'liberx/program/wake.c', 'liberx/program/pages.c', 'liberx/program/inbound.c', 'liberx/program/startup.c',
             'liberx/erx_pipe_core.c', 'liberx/erx_pipe_check.c', 'liberx/erx_pipe_run.c',
             'liberx/erx_profile.c', 'liberx/erx_etf.c', 'kernel/crypto/blake3/blake3.c',
             'kernel/crypto/blake3/blake3_portable.c', 'build/gen/liberx/generated/prog_profile.c',
             'build/gen/liberx/generated/abi_reader.c', 'test/fixtures/prog_fd_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread'].freeze
  ASAN = ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  TSAN = ['-fsanitize=thread'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  F = ProgProfileFrames
  E = ProgProfileFrames::Etf
  EBADF = Errno::EBADF::Errno
  EPIPE = Errno::EPIPE::Errno
  EINVAL = Errno::EINVAL::Errno
  EACCES = Errno::EACCES::Errno
  ENODEV = Errno::ENODEV::Errno
  ESPIPE = Errno::ESPIPE::Errno
  ENOTSUP = Errno::ENOTSUP::Errno
  ENOTTY = Errno::ENOTTY::Errno
  ENOMEM = -6 # ERX_ENOMEM

  def self.int(value) = value < 256 ? E.small(value) : E.int(value)
  def self.pairs(map) = E.map(map.map { |key, value| [E.atom(key.to_s), value] })
  def self.report(*items) = E.frame(E.tuple(E.atom('erx_prog'), E.small(1), E.tuple(*items))).unpack1('H*')

  # Pipe 7: its write end 2 at fd 1 (ring 101, reader page 102, read end 0's doorbell 103), and
  # its read end 1 at fd 0 (lock page 104, write end 1's lane as 105 and 106, the same objects
  # as 101 and 102, and its doorbell 107).
  WRITE_END = E.tuple(E.atom('pipe'), E.atom('write'), E.tuple(int(7), int(2)),
                      pairs(wend: int(1), ring: int(101), rpage: int(102), size: int(65_536),
                            readers: E.list([E.tuple(int(0), int(103))])))
  READ_END = E.tuple(E.atom('pipe'), E.atom('read'), E.tuple(int(7), int(1)),
                     pairs(rix: int(0), lock: int(104), wends: int(1),
                           writers: E.list([E.tuple(int(1), int(105), int(106), int(65_536),
                                                    E.tuple(E.atom('open'), int(107)))]),
                           readers: E::NIL))
  START = F.start(F::BASE_PAIRS.merge(fds: E.list([E.tuple(int(0), READ_END), E.tuple(int(1), WRITE_END),
                                                   E.tuple(int(2), E.atom('null'))]))).unpack1('H*')
  MEM_START = F.start(F::BASE_PAIRS.merge(fds: E.list([E.tuple(int(0), E.atom('null')),
                                                       E.tuple(int(3), E.tuple(E.atom('mem'), int(16), int(2)))])))
               .unpack1('H*')
  # Two mem ranges, which the startup plan refuses at the second: the table holds one.
  TWO_MEM_START = F.start(F::BASE_PAIRS.merge(fds: E.list([E.tuple(int(3), E.tuple(E.atom('mem'), int(16), int(2))),
                                                           E.tuple(int(4), E.tuple(E.atom('mem'), int(32), int(1)))])))
                   .unpack1('H*')
  # A mem range of two pages the fixture backs with host memory it reserved wherever
  # the host put it: the start message carries a stand-in page the fixture replaces
  # (@P), and addresses in the range are the reserve's plus or minus an offset (@A).
  MEM_PAGE_STAND_IN = '7eadbeef'
  REAL_MEM_START = F.start(F::BASE_PAIRS.merge(fds: E.list([E.tuple(int(3), E.tuple(E.atom('mem'),
                                                                                  int(MEM_PAGE_STAND_IN.to_i(16)), int(2)))])))
                    .unpack1('H*').tap { |hex| raise 'stand-in page not unique' unless hex.scan(MEM_PAGE_STAND_IN).one? }
                    .sub(MEM_PAGE_STAND_IN, '@P')
  def self.at(offset) = offset.negative? ? "@A-#{(-offset).to_s(16)}" : "@A+#{offset.to_s(16)}"
  SET_UP = [['alias 105 101', 'alias'], ['alias 106 102', 'alias'], ["start #{START}", 'setup 0']].freeze
  READ_STATE = 'read 7 1 refs=1 rix=0 known=1 lost=0 peers=0 lanes=1:open:107'
  # The read end's doorbell, 103, and the write end's, 107, come up as their labels, (7 << 32) | End.
  BOUND = [*SET_UP, ["bind 103 #{(7 << 32) | 1}", 'bound'], ["bind 107 #{(7 << 32) | 2}", 'bound']].freeze
  WRITER_GONE = "report #{report(E.atom('pipe_writer_gone'), int(7), int(1), int(1))}".freeze
  READER_GONE = "report #{report(E.atom('pipe_reader_gone'), int(7), int(2), int(0))}".freeze
  WRITE_STATE = 'write 7 2 refs=1 readers=1 lost=0 size=65536 peers=1'

  # Calls that wait, on real threads; these run under the thread sanitizer as well.
  THREADED = {
    # Both threads wait on the read end; the ring of its doorbell wakes both, one takes the
    # record and the other waits again, for the next.
    'two threads on one end' => [*BOUND, ['spawn 0 fdread 0 2', 'spawned'], ['spawn 1 fdread 0 2', 'spawned'],
                                 ['waiters 0 2', '2'], ['fdwrite 1 ab', '2'], ['waiters 0 1', '1'],
                                 ['fdwrite 1 ab', '2'], ['join 0', '2 ab'], ['join 1', '2 ab'], ['waiters 0 0', '0']],
    # A read of 0 bytes gives up the wait's sleepers bits; the waiting thread, woken for it,
    # publishes them again, so the write that follows rings it.
    'a call wakes the calls whose wait it ended' => [*BOUND, ['spawn 0 fdread 0 8', 'spawned'], ['waiters 0 1', '1'],
                                                     ['bitswait sleepers 102 1', '1'], ['fdread 0 0', '0'],
                                                     ['bitswait sleepers 102 1', '1'], ['fdwrite 1 x', '1'],
                                                     ['join 0', '1 x']],
    # The writer's going wakes the read, which finds the lane drained, returns the end of the
    # stream and sends {drained}; the release then sends {closed}.
    'a report wakes a read' => [*BOUND, ['spawn 0 fdread 0 8', 'spawned'], ['waiters 0 1', '1'], [WRITER_GONE, 'applied'],
                                ['join 0', '0'], ['notices', 'drained:7:1:1'], ['close 0', '0'],
                                ['notices', 'drained:7:1:1 closed:7:1']],
    # A write larger than the ring publishes what fits, waits for room, and on the reader's
    # ring of its doorbell writes the rest from where it stopped; it returns the whole count.
    'a write waits for room' => [*BOUND, ['spawn 0 fdwriten 1 100000', 'spawned'], ['waiters 1 1', '1'],
                                 ['spawn 1 fdreadn 0 100000', 'spawned'], ['join 1', '100000'], ['join 0', '100000']],
    # A write that published what fits and waits for room fails with EPIPE when the last read
    # end goes, not with the count it wrote, as FreeBSD's write does.
    'a write that meets a gone reader fails' => [*BOUND, ['spawn 0 fdwriten 1 100000', 'spawned'], ['waiters 1 1', '1'],
                                                 ["report #{report(E.atom('pipe_reader_gone'), int(7), int(2), int(0))}",
                                                  'applied'],
                                                 ['join 0', "-#{EPIPE}"]],
    # A poll's registrations: one thread on both ends' lists, woken by a report to the second,
    # leaves both.
    'a poll watches two ends' => [*BOUND, ['spawn 0 watch 0 1', 'spawned'], ['waiters 0 1', '1'], ['waiters 1 1', '1'],
                                  ["report #{report(E.atom('pipe_reader_gone'), int(7), int(2), int(0))}", 'applied'],
                                  ['join 0', 'woke'], ['waiters 0 0', '0'], ['waiters 1 0', '0']]
  }.freeze

  CASES = {
    'set-up' => [*SET_UP, ['state 0', READ_STATE], ['state 1', WRITE_STATE],
                 ['write 1 hello', '5'], ['read 0 64', '5 hello'], ['caps', 'none']],
    'dup and close' => [*SET_UP, ['dup 1', '3'], ['close 1', '0'], ['notices', 'none'],
                        ['state 3', WRITE_STATE], ['close 3', '0'], ['notices', 'closed:7:2'],
                        ['close 3', "-#{EBADF}"], ['close 2', '0'], ['close 0', '0'],
                        ['notices', 'closed:7:2 closed:7:1'], ['maps', '0'],
                        ['caps', '101:1:0 102:1:0 103:1:0 104:1:0 105:1:0 106:1:0 107:1:0']],
    'close while held' => [*SET_UP, ['hold 0', 'held'], ['close 0', '0'], ['hold 0', 'none'],
                           ['notices', 'none'], ['drop', 'dropped'], ['notices', 'closed:7:1']],
    'release ends the wait' => [*SET_UP, ['read 0 64', 'WAIT'], ['bits sleepers 102', '1'], ['close 0', '0'],
                                ['bits sleepers 102', '0'], ['notices', 'closed:7:1']],
    # A poll answers without copying: room for PIPE_BUF bytes is POLLOUT (4); an empty read end
    # arms its sleepers bit and reports nothing, then POLLIN (1) once a record is there, which a
    # read still returns whole.
    # As FreeBSD's pipe_poll reports, the end of the stream is POLLIN|POLLHUP (17), and a write
    # end with no read end POLLOUT|POLLHUP (20), so a writer wakes and meets EPIPE.
    'poll' => [*SET_UP, ['poll 1', '4'], ['poll 0', '0'], ['bits sleepers 102', '1'], ['write 1 x', '1'],
               ['poll 0', '1'], ['bits sleepers 102', '0'], ['read 0 8', '1 x'], [WRITER_GONE, 'applied'],
               ['poll 0', '17'], [READER_GONE, 'applied'], ['poll 1', '20']],
    # A poll that answered 0 and stops watching the end, the last to wait on it, withdraws the
    # sleepers bit it published, so the idle end is rung by no write.
    'a poll given up' => [*SET_UP, ['poll 0', '0'], ['bits sleepers 102', '1'], ['unwatch 0', 'unwatched'],
                          ['bits sleepers 102', '0'], ['unwatch 1', 'unwatched']],
    'take clears bits' => [['alias 105 101', 'alias'], ['alias 106 102', 'alias'],
                           ['setbits waiters 104 5', 'set'], ['setbits sleepers 102 1', 'set'],
                           ["start #{START}", 'setup 0'], ['bits waiters 104', '4'], ['bits sleepers 102', '0'],
                           ['write 1 x', '1'], ['read 0 8', '1 x']],
    'reports' => [*SET_UP,
                  *(2..6).map do |wend|
                    ["report #{report(E.atom('pipe_writer'), int(7), int(1), int(wend), int(100 + (10 * wend)),
                                      int(101 + (10 * wend)), int(16_384), int(102 + (10 * wend)),
                                      E.atom(wend == 6 ? 'gone' : 'open'))}", 'applied']
                  end,
                  ['state 0', 'read 7 1 refs=1 rix=0 known=6 lost=0 peers=0 ' \
                              'lanes=1:open:107,2:open:122,3:open:132,4:open:142,5:open:152,6:gone:0'],
                  ["report #{report(E.atom('pipe_writer_gone'), int(7), int(1), int(1))}", 'applied'],
                  ["report #{report(E.atom('pipe_reader'), int(7), int(2), int(1), int(113), E.atom('open'))}",
                   'applied'],
                  ["report #{report(E.atom('pipe_reader_gone'), int(7), int(2), int(0))}", 'applied'],
                  ["report #{report(E.atom('pipe_writer'), int(7), int(99), int(9), int(190), int(191),
                                    int(16_384), int(193), E.atom('open'))}", 'applied'],
                  ["report #{report(E.atom('pipe_lost'), int(7), int(1))}", 'applied'],
                  ['state 0', 'read 7 1 refs=1 rix=0 known=6 lost=1 peers=0 ' \
                              'lanes=1:gone:0,2:open:122,3:open:132,4:open:142,5:open:152,6:gone:0'],
                  ['state 1', 'write 7 2 refs=1 readers=1 lost=0 size=65536 peers=2'],
                  ["report #{E.frame(E.tuple(E.atom('erx_prog'), E.small(1),
                                             E.atom('pipe_server_lost'))).unpack1('H*')}", 'applied'],
                  ['state 1', 'write 7 2 refs=1 readers=1 lost=1 size=65536 peers=2'],
                  ['caps', '103:1:0 107:1:0 113:0:1 122:0:1 132:0:1 142:0:1 152:0:1 162:1:0 190:1:0 ' \
                           '191:1:0 193:1:0'],
                  ['close 0', '0'], ['close 1', '0'], ['maps', '0']],
    # The write end's reader page fails to map, after its ring did: the set-up fails and gives
    # back the ring's whole mapping and the capabilities it kept.
    'failed set-up' => [['alias 105 101', 'alias'], ['alias 106 102', 'alias'], ['failmap 5', 'armed'],
                        ["start #{START}", "setup #{ENOMEM}"], ['caps', '101:1:0 102:1:0 103:1:0']],
    # A mem range at fd 3, pages 16 and 17, which the session mapped: mmap returns its address
    # only for MAP_SHARED alone, offset 0, a length within it and no more than read and write;
    # fstat gives its size; it is no stream; it survives a dup and its close maps nothing.
    'a second mem range' => [["start #{TWO_MEM_START}", 'refused 2 4'], ['fdstat 3', "#{-EBADF} 0 0"]],
    'a mem range' => [["start #{MEM_START}", 'setup 0'], ['fdstat 3', '0 100600 8192'], ['fdstat 0', '0 20666 0'],
                      ['fdmmap 3 8192 rw shared 0', '0 10000'], ['fdmmap 3 1 r shared 0', '0 10000'],
                      ['fdmmap 3 8193 rw shared 0', "#{-EINVAL} 0"], ['fdmmap 3 0 rw shared 0', "#{-EINVAL} 0"],
                      ['fdmmap 3 4096 rw shared 4096', "#{-EINVAL} 0"],
                      ['fdmmap 3 4096 rw private 0', "#{-EINVAL} 0"],
                      ['fdmmap 3 4096 rw shared+fixed 0', "#{-EINVAL} 0"],
                      ['fdmmap 3 4096 rwx shared 0', "#{-ENOTSUP} 0"],
                      ['fdseek 3', (-ESPIPE).to_s], ['fdseek 0', '0'], ['fdseek 5', (-EBADF).to_s],
                      ['fdioctl 0', (-ENOTTY).to_s], ['fdioctl 5', (-EBADF).to_s], ['fdmmap 0 4096 rw shared 0', "#{-ENODEV} 0"],
                      ['fdmmap 5 4096 rw shared 0', "#{-EBADF} 0"], ['fdwrite 3 ab', (-ESPIPE).to_s],
                      ['dup 3', '1'], ['close 3', '0'], ['fdstat 1', '0 100600 8192'], ['close 1', '0'],
                      ['fdstat 3', "#{-EBADF} 0 0"], ['maps', '0']],
# docs/design-programs.md#the-startup-message: while a descriptor holds the mem range, a
# munmap inside it unmaps nothing, so a byte written before reads back after; one a page
# across either end and a fixed mmap inside fail; munmap's own checks come first; and once
# the last descriptor closed, a munmap of the range releases it.
"a mem range's memory rules" =>
  [['reserve 2', 'reserved'], ["start #{REAL_MEM_START}", 'setup 0'],
   ["poke #{at(4096)} 5a", 'poked'], ["munmap #{at(4096)} 1000", '0'],
   ["munmap #{at(0)} 2000", '0'], ["peek #{at(4096)}", '5a'],
   ["munmap #{at(-4096)} 2000", (-EINVAL).to_s],
   ["munmap #{at(4096)} 2000", (-EINVAL).to_s],
   ["fixed #{at(4096)} 1000", (-EINVAL).to_s],
   ["fixed #{at(8192)} 1000", '0'],
   ["munmap #{at(1)} 1000", (-EINVAL).to_s],
   ["munmap #{at(0)} 0", (-EINVAL).to_s],
   ["munmap #{(2**64 - 4096).to_s(16)} 2000", (-EINVAL).to_s],
   ["munmap #{at(0)} ffffffffffffffff", (-EINVAL).to_s],
   ['dup 3', '0'], ['close 3', '0'], ["munmap #{at(0)} 2000", '0'], ['close 0', '0'],
   ["munmap #{at(0)} 2000", '0'], ['maps', '0']],
    # Reports the end cannot take close what they carry, but never a value the end holds.
    'repeated reports' => [*SET_UP,
                           ["report #{report(E.atom('pipe_reader'), int(7), int(1), int(0), int(130), E.atom('open'))}",
                            'applied'],
                           ["report #{report(E.atom('pipe_reader'), int(7), int(1), int(2), int(131), E.atom('gone'))}",
                            'applied'],
                           ["report #{report(E.atom('pipe_reader'), int(7), int(2), int(0), int(103), E.atom('open'))}",
                            'applied'],
                           ["report #{report(E.atom('pipe_reader'), int(7), int(2), int(0), int(132), E.atom('open'))}",
                            'applied'],
                           ["report #{report(E.atom('pipe_writer'), int(7), int(1), int(1), int(105), int(106),
                                             int(65_536), int(107), E.atom('open'))}", 'applied'],
                           ["report #{report(E.atom('pipe_writer'), int(7), int(1), int(1), int(140), int(141),
                                             int(65_536), int(142), E.atom('open'))}", 'applied'],
                           ['state 0', READ_STATE], ['state 1', WRITE_STATE],
                           ['caps', '103:1:1 130:1:0 131:1:0 132:0:1 140:1:0 141:1:0 142:1:0'],
                           ['close 0', '0'], ['close 1', '0'], ['maps', '0']],
    'locked' => [*SET_UP, ["locked 1 #{report(E.atom('pipe_lost'), int(7), int(2))}", 'waited'],
                 ['state 1', 'write 7 2 refs=1 readers=1 lost=1 size=65536 peers=1']],
    # read and write through the table: a pipe end's, null's, and an empty slot's.
    'calls' => [*SET_UP, ['fdwrite 1 hi', '2'], ['fdread 0 8', '2 hi'], ['fdwrite 2 abc', '3'], ['fdread 2 8', '0'],
                ['fdread 1 8', "-#{EBADF}"], ['fdwrite 0 x', "-#{EBADF}"], ['fdread 9 8', "-#{EBADF}"]],
    **THREADED
  }.freeze

  # A seeded fault, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'an inside munmap is passed on to the release' =>
      ["a mem range's memory rules", FD, "\tcase RANGE_INSIDE:\n\t\treturn (0);\n", "\tcase RANGE_INSIDE:\n"],
    'an unaligned munmap is let through' =>
      ["a mem range's memory rules", FD, ' || (addr & page_mask) != 0)', ')'],
    "a munmap's end wraps" =>
      ["a mem range's memory rules", FD, "if (__builtin_add_overflow(addr, size, &end))\n\t\treturn (-EINVAL);\n\tswitch",
       "end = addr + size;\n\tswitch"],
    'a mem range is remembered after its release' =>
      ["a mem range's memory rules", FD, "\t\tmem_held = NULL;\n\t\treturn (true);", "\t\treturn (true);"],
    'a mem range is forgotten while held' =>
      ["a mem range's memory rules", FD, "\t\t\tmem_held = mem_of(obj);\n", ""],
    'a mmap one byte past a mem range is let through' =>
      ['a mem range', FD, 'len > mem->bytes)', 'len > mem->bytes + 1)'],
    'a mem object is let go at its first close while a dup still holds it' =>
      ['a mem range', FD, "if (--obj->refs != 0)\n\t\t\treturn (false);\n\t\tmem_held = NULL;", "if (--obj->refs >= 2)\n\t\t\treturn (false);\n\t\tmem_held = NULL;"],
    'the last reference is miscounted, so {closed} is sent early and again' => ['dup and close', FD, "if (--obj->refs != 0)\n\t\t\treturn (false);\n\t\tif (obj->prev", "if (--obj->refs > 1)\n\t\t\treturn (false);\n\t\tif (obj->prev"],
    'a report is applied without the end lock' =>
      ['locked', FD, "\t\terx_pipe_end_lock(found);\n", ''],
    'a read end takes its index without rtake' =>
      ['take clears bits', PIPE, 'return (erx_pipe_rtake(&r->st, v->rix, r->maps, r->lockpage) ? ERX_OK : ERX_EINVAL);',
       'return (r->st.rix = v->rix, ERX_OK);'],
    'a failed write end gives its ring back by the size it never set' =>
      ['failed set-up', PIPE, "\tw->st.size = v->size;\n", ''],
    'a repeated report closes a doorbell the end holds' =>
      ['repeated reports', PIPE, "\tif (e->peers[rix] != bell)\n\t\tcap_close(&e->peers[rix]);",
       "\tcap_close(&e->peers[rix]);"],
    'the release unmaps without ending the wait' =>
      ['release ends the wait', PIPE, "\t\t\terx_pipe_rstart(&e->u.r.st, 0);\n",
       "\t\t\terx_pipe_rstart(&e->u.r.st, 0);\n\t\t\te->u.r.st.taken = false;\n"],
    'a read that clears what other calls wait on does not wake them' =>
      ['a call wakes the calls whose wait it ended', PIPE,
       "\t\tif (r->st.wake_local)\n\t\t\terx_prog_waitq_wake(&e->waiters);\n", ''],
    'a ring of the doorbell wakes nobody' =>
      ['two threads on one end', PIPE, "\t\terx_prog_waitq_wake(&e->waiters);\n\t\terx_pipe_end_unlock(e);\n",
       "\t\terx_pipe_end_unlock(e);\n"],
    'a report wakes nobody' => ['a report wakes a read', PIPE, "\t\tbreak;\n\t}\n\terx_prog_waitq_wake(&e->waiters);\n}",
                                "\t\tbreak;\n\t}\n}"],
    'a write after a wait starts again from its first byte' =>
      ['a write waits for room', PIPE, "\t\twritten += w->st.done;\n", ''],
    'a read keeps its {drained}' => ['a report wakes a read', PIPE, "\tif (owes)\n\t\tdrained_send(e);\n\treturn (",
                                    "\tif (owes && false)\n\t\tdrained_send(e);\n\treturn ("],
    "an unwatch that leaves a read end idle with its poll's sleepers bit" =>
      ['a poll given up', PIPE, 'if (last && e->kind == ERX_PIPE_READ)', 'if (false && last)'],
    'a poll stays on an end it unwatched' =>
      ['a poll watches two ends', PIPE, "\terx_pipe_end_lock(e);\n\terx_prog_waitq_leave(&e->waiters, w);\n",
       "\terx_pipe_end_lock(e);\n\t(void)w;\n"],
    'a read returns holding the end lock, and the table lock is taken under it' =>
      ['calls', PIPE, "\towes = r->owing != 0;\n\terx_pipe_end_unlock(e);\n", "\towes = r->owing != 0;\n"]
  }.freeze

  def test_each_case_under_the_address_and_undefined_sanitizers
    with_driver({}, ASAN) do |driver|
      CASES.each do |name, steps|
        assert_equal steps.map(&:last), run_case(driver, steps), name
      end
    end
  end

  def test_threaded_cases_under_the_thread_sanitizer
    with_driver({}, TSAN) do |driver|
      THREADED.each do |name, steps|
        assert_equal steps.map(&:last), run_case(driver, steps), name
      end
    end
  end

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, (kase, file, original, replacement)|
      source = File.read(File.join(ROOT, file))
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
      with_driver({ file => source.sub(original, replacement) }, ASAN) do |driver|
        steps = CASES.fetch(kase)
        refute_equal steps.map(&:last), run_case(driver, steps), "seeded fault not caught: #{name}"
      end
    end
  end

  private

  # Builds the driver from SOURCES, each source named in replaced taking the text it maps to.
  def with_driver(replaced, sanitizers)
    Dir.mktmpdir('erx-prog-fd-') do |directory|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(directory, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
      end
      binary = File.join(directory, 'driver')
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                  '-I', File.join(ROOT, 'kernel/crypto')]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *sanitizers, *includes, *sources, '-o', binary, stdin_data: '')
      assert status.success?, "compiling the driver failed:\n#{output}"
      yield binary
    end
  end

  # The driver's answers to the case's requests, a line each, or all it printed when it stopped.
  def run_case(driver, steps)
    Dir.mktmpdir('erx-prog-fd-case-') do |directory|
      requests = File.join(directory, 'requests')
      File.write(requests, steps.map { |request, _| "#{request}\n" }.join)
      output, = Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, 'gtimeout', '-k', '10', '120',
                                driver, requests, stdin_data: '')
      output.lines(chomp: true)
    end
  end
end
