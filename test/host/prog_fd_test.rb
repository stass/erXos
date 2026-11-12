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
# the end it names under the end's lock, or closes what it installed when no end is held
# (docs/design-pipes.md, "Ends in liberx" and "Ends and their holders";
# docs/design-programs.md, "Descriptors and files"). Every case runs under the address and
# undefined sanitizers, and each seeded fault must fail the case named beside it.
class ProgFdTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  FD = 'liberx/program/fd.c'
  PIPE = 'liberx/program/pipe.c'
  SOURCES = [FD, PIPE, 'liberx/program/pages.c', 'liberx/program/inbound.c', 'liberx/program/startup.c',
             'liberx/erx_pipe_core.c', 'liberx/erx_pipe_check.c', 'liberx/erx_pipe_run.c',
             'liberx/erx_profile.c', 'liberx/erx_etf.c', 'kernel/crypto/blake3/blake3.c',
             'kernel/crypto/blake3/blake3_portable.c', 'build/gen/liberx/generated/prog_profile.c',
             'build/gen/liberx/generated/abi_reader.c', 'test/fixtures/prog_fd_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  F = ProgProfileFrames
  E = ProgProfileFrames::Etf
  EBADF = Errno::EBADF::Errno
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
  SET_UP = [['alias 105 101', 'alias'], ['alias 106 102', 'alias'], ["start #{START}", 'setup 0']].freeze
  READ_STATE = 'read 7 1 refs=1 rix=0 known=1 lost=0 peers=0 lanes=1:open:107'
  WRITE_STATE = 'write 7 2 refs=1 readers=1 lost=0 size=65536 peers=1'

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
                 ['state 1', 'write 7 2 refs=1 readers=1 lost=1 size=65536 peers=1']]
  }.freeze

  # A seeded fault, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'the last reference is miscounted, so {closed} is sent early and again' => ['dup and close', FD, 'if (--obj->refs != 0)', 'if (--obj->refs > 1)'],
    'a report is applied without the end lock' =>
      ['locked', FD, "\t\t(void)pthread_mutex_lock(&found->lock);\n", ''],
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
       "\t\t\terx_pipe_rstart(&e->u.r.st, 0);\n\t\t\te->u.r.st.taken = false;\n"]
  }.freeze

  def test_each_case_under_the_address_and_undefined_sanitizers
    with_driver({}) do |driver|
      CASES.each do |name, steps|
        assert_equal steps.map(&:last), run_case(driver, steps), name
      end
    end
  end

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, (kase, file, original, replacement)|
      source = File.read(File.join(ROOT, file))
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
      with_driver({ file => source.sub(original, replacement) }) do |driver|
        steps = CASES.fetch(kase)
        refute_equal steps.map(&:last), run_case(driver, steps), "seeded fault not caught: #{name}"
      end
    end
  end

  private

  # Builds the driver from SOURCES, each source named in replaced taking the text it maps to.
  def with_driver(replaced)
    Dir.mktmpdir('erx-prog-fd-') do |directory|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(directory, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
      end
      binary = File.join(directory, 'driver')
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                  '-I', File.join(ROOT, 'kernel/crypto')]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes, *sources, '-o', binary, stdin_data: '')
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
