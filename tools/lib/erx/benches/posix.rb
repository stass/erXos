# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bench_suite'

# What a program sees (docs/design-bench.md, "What a program sees: `posix` and `erl`"):
# ordinary POSIX calls and UNIX IPC as erx_peer_bench's posix benchmark issues them, the
# same C file on erXos, as a program of root's session, and on Linux's guest. Each
# operation says whether both systems do the same work for the call (same act) or what
# differs (nearest counterpart), and the program table prints it. These are the rows the
# design marks as running on erXos, the thread forms of the pipe rows, and stat, whose
# first untimed call shows the probe answering unsupported where erXos has no call yet.
operation = Erx::BenchSuite::Operation
cell = Erx::BenchSuite::LandingCell
same = 'same act'
user_clock = 'nearest counterpart: erXos reads and scales the counter in user mode; Linux does too where its ' \
             "static binary finds the kernel's user-mode clock_gettime, and otherwise enters its kernel"
commit = 'nearest counterpart: erXos commits the pages at mmap, Linux at the first touch'
linux = ->(line) { { 'linux' => line } }
file = 'the same call on a file of the initramfs root, in memory'
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'getpid', profile: 'fast', result: 'the same positive value every call',
                  act: 'nearest counterpart: erXos answers in user mode where Linux enters its kernel; the row ' \
                       'is what a program pays, not what a system call costs on erXos',
                  counterparts: linux.call("musl's getpid, a system call")),
    operation.new(name: 'clock-gettime', profile: 'fast', result: 'returns 0, never decreasing', act: user_clock,
                  counterparts: linux.call("musl's clock_gettime of CLOCK_MONOTONIC")),
    operation.new(name: 'open', profile: 'fast', act: same, counterparts: linux.call(file),
                  result: 'every open returns the same descriptor, the lowest free, and one more open after the loop ' \
                          'still returns it'),
    operation.new(name: 'close', profile: 'fast', act: same, counterparts: linux.call(file),
                  result: 'every close returns 0, and one more open after the loop returns the lowest free descriptor'),
    operation.new(name: 'fstat', profile: 'fast', act: same, counterparts: linux.call(file),
                  result: 'size 65536 and a regular file'),
    operation.new(name: 'stat', profile: 'fast', act: same, counterparts: linux.call(file),
                  result: 'size 65536 and a regular file'),
    operation.new(name: 'read', profile: 'fast', act: same, counterparts: linux.call(file),
                  result: 'pread at offset 0 returns the count asked, and the bytes are the pattern'),
    operation.new(name: 'write', profile: 'fast', act: same, counterparts: linux.call(file),
                  result: 'pwrite at offset 0 returns the count asked, and the bytes read back'),
    operation.new(name: 'read-seq', profile: 'expensive', act: same, counterparts: linux.call(file),
                  result: 'a 16 MiB file read from start to end in 64 KiB calls, every count full'),
    operation.new(name: 'write-seq', profile: 'expensive', act: same, counterparts: linux.call(file),
                  result: 'a 16 MiB file written from start to end in 64 KiB calls, every count full'),
    operation.new(name: 'copy', profile: 'expensive', act: same, counterparts: linux.call(file),
                  result: 'the 16 MiB file copied in 64 KiB parts to a truncated second file reads back equal'),
    operation.new(name: 'pipe-rtt', profile: 'fast', act: same,
                  counterparts: linux.call('the same round trip over two pipes, copied through its kernel'),
                  result: 'every reply equals its request, whose first bytes carry its sequence number'),
    operation.new(name: 'poll-rtt', profile: 'fast', act: same,
                  counterparts: linux.call('the same round trip, each side blocking in poll'),
                  result: 'every reply equals its request, and every poll reports POLLIN'),
    operation.new(name: 'pipe-stream', profile: 'expensive', act: same,
                  counterparts: linux.call('the same stream through a pipe of its kernel'),
                  result: "64 MiB in 64 KiB writes; B's count and checksum equal A's"),
    operation.new(name: 'mutex-handoff', profile: 'fast', handshake: true, act: same,
                  counterparts: linux.call("musl's mutex over its kernel's futex"),
                  result: 'B always gets the mutex A unlocks'),
    operation.new(name: 'cond-pingpong', profile: 'fast', act: same,
                  counterparts: linux.call("musl's condition variables over its kernel's futex"),
                  result: 'every turn seen in order'),
    operation.new(name: 'thread-create-join', profile: 'fast', act: same,
                  counterparts: linux.call("musl's pthread_create over clone, and pthread_join"),
                  result: "both return 0 and the join returns the thread's value"),
    operation.new(name: 'nanosleep', profile: 'expensive', act: same,
                  counterparts: linux.call('nanosleep, a timed wait in its kernel'),
                  result: 'a sample is the interval less the sleep asked; an interval under it is an early return'),
    operation.new(name: 'mmap', profile: 'fast', act: commit, counterparts: linux.call('an anonymous private mmap'),
                  result: 'every page reads zero'),
    operation.new(name: 'touch', profile: 'fast', act: commit,
                  counterparts: linux.call('the first write to a page, a fault in its kernel'),
                  result: 'each page written reads back'),
    operation.new(name: 'munmap', profile: 'fast', act: same, counterparts: linux.call('munmap'),
                  result: 'mprotect of the range afterwards fails with ENOMEM'),
    operation.new(name: 'map-cycle', profile: 'fast', act: same, counterparts: linux.call('mmap, touch and munmap'),
                  result: 'the checks of mmap, touch and munmap, untimed')
  ],
  landing: {
    'posix' => [
      *%w[getpid clock-gettime open close fstat stat].map do |name|
        cell.new(operation: name, load: 'idle', placement: 'same-cpu', parameters: {})
      end,
      *%w[read write].product([4096, 65_536]).map do |name, bytes|
        cell.new(operation: name, load: 'idle', placement: 'same-cpu', parameters: { 'bytes' => bytes })
      end,
      *%w[read-seq write-seq copy].map do |name|
        cell.new(operation: name, load: 'idle', placement: 'same-cpu', parameters: { 'bytes' => 16_777_216 })
      end,
      *%w[same-cpu cross-cpu].product([1, 65_536]).map do |placement, bytes|
        cell.new(operation: 'pipe-rtt', load: 'idle', placement: placement, parameters: { 'peer' => 'thread', 'bytes' => bytes })
      end,
      *%w[same-cpu cross-cpu].flat_map do |placement|
        [cell.new(operation: 'poll-rtt', load: 'idle', placement: placement, parameters: { 'peer' => 'thread', 'bytes' => 1 }),
         cell.new(operation: 'pipe-stream', load: 'idle', placement: placement,
                  parameters: { 'peer' => 'thread', 'bytes' => 67_108_864 }),
         cell.new(operation: 'cond-pingpong', load: 'idle', placement: placement, parameters: {})]
      end,
      cell.new(operation: 'mutex-handoff', load: 'idle', placement: 'cross-cpu', parameters: {}),
      cell.new(operation: 'thread-create-join', load: 'idle', placement: 'same-cpu', parameters: {}),
      cell.new(operation: 'nanosleep', load: 'idle', placement: 'same-cpu', parameters: { 'ns' => 1_000_000 }),
      *%w[mmap munmap].product([1, 64]).map do |name, pages|
        cell.new(operation: name, load: 'idle', placement: 'same-cpu', parameters: { 'pages' => pages })
      end,
      *%w[touch map-cycle].map do |name|
        cell.new(operation: name, load: 'idle', placement: 'same-cpu', parameters: { 'pages' => 64 })
      end
    ]
  }
)
