# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/prog_profile_frames'

# liberx's start-up core, erx_prog_startup_plan (liberx/program/startup.h), through
# test/fixtures/prog_startup_driver.c: the hand-encoded start frames of
# test/fixtures/prog_profile_frames.rb, and frames built here from their pieces, plan to the
# argv, env and cwd written by hand, or end with status 127 for the check's refusal, a
# descriptor other than null, or any frame after the startup message
# (docs/design-programs.md#the-startup-message, docs/design-abi.md#program-protocol, Startup).
class ProgStartupTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  PLAN = 'liberx/program/startup.c'
  SOURCES = [PLAN, 'liberx/erx_profile.c', 'liberx/erx_etf.c', 'kernel/crypto/blake3/blake3.c',
             'kernel/crypto/blake3/blake3_portable.c', 'build/gen/liberx/generated/prog_profile.c',
             'test/fixtures/prog_startup_driver.c'].freeze
  CFLAGS = %w[-std=c17 -Wall -Wextra -Werror -pedantic].freeze
  F = ProgProfileFrames
  E = ProgProfileFrames::Etf
  BASE = F::BASE_PAIRS.merge(fds: E::NIL).freeze
  PATH_MAX = 4096

  # name => [frame, expected answer]: a Hash of the go line's fields, or the refusal's words.
  def self.go(argv:, env:, cwd:, **fields) = { argv: argv, env: env, cwd: cwd, **fields }

  BUILT = {
    base: [F.start(BASE), go(argv: ['prog'], env: ['HOME=/'], cwd: '/', pid: '2', ppid: '1', pgid: '2',
                             spawn: '0', umask: '18', data_area: '100', data_slots: '4',
                             sigmask: '0' * 32, sigignore: '0' * 32, fds: [])],
    # ENCODINGS' pieces with no descriptor: argv as bits, an empty env, cwd as bits, signals.
    encodings: [F.start(BASE.merge(pid: E.int(2), argv: E.list([E.bits('prog'), E.binary('a')]), env: E::NIL,
                                   cwd: E.bits('/home'), spawn: E.long_atom('true'),
                                   sigmask: E.list([E.long_atom('sigint'), E.atom('sigterm')]),
                                   sigignore: E.string('')).to_a.reverse),
                go(argv: %w[prog a], env: [], cwd: '/home', spawn: '1',
                   sigmask: format('%032x', (1 << 1) | (1 << 14)), sigignore: '0' * 32)],
    texts: [F.start(BASE.merge(argv: E.list([E.binary(''), E.binary('x y')]),
                               env: E.list([E.binary('A=1'), E.binary('B=')]), cwd: E.binary('/a/b'))),
            go(argv: ['', 'x y'], env: ['A=1', 'B='], cwd: '/a/b', argv_bytes: '5', env_bytes: '7')],
    capabilities: [F.start(BASE.merge(data_area: E.tuple(E.small_big(2**63), E.small(16)),
                                      image: E.tuple(E.atom('object'), E.small_big(2**64 - 1)))),
                   go(argv: ['prog'], env: ['HOME=/'], cwd: '/', data_area: (2**63).to_s, data_slots: '16',
                      image: (2**64 - 1).to_s)],
    args_total: [F.start(BASE.merge(argv: E.list([E.binary('a' * (F::ARGS_MAX - 1))]), env: E::NIL)),
                 go(argv: ['a' * (F::ARGS_MAX - 1)], env: [], cwd: '/', argc: '1', argv_bytes: F::ARGS_MAX.to_s)],
    cwd_at_max: [F.start(BASE.merge(cwd: E.binary('/' + ('c' * (PATH_MAX - 1))))),
                 go(argv: ['prog'], env: ['HOME=/'], cwd: '/' + ('c' * (PATH_MAX - 1)))],
    nulls: [F.start(BASE.merge(fds: E.list([E.tuple(E.small(0), E.atom('null')), E.tuple(E.small(2), E.atom('null'))]))),
            go(argv: ['prog'], env: ['HOME=/'], cwd: '/', fds: %w[0 2])],
    # The lowest and highest signal numbers of each 64-bit half of a set.
    signals: [F.start(BASE.merge(sigmask: E.list(%w[sighup sigrtmax sigrtmin].map { |name| E.atom(name) }),
                                 sigignore: E.list([E.atom('sigpipe')]))),
              go(argv: ['prog'], env: ['HOME=/'], cwd: '/',
                 sigmask: format('%032x', (1 << 0) | (1 << 64) | (1 << 125)),
                 sigignore: format('%032x', 1 << 12))],
    cwd_past_max: [F.start(BASE.merge(cwd: E.binary('/' + ('c' * PATH_MAX)))), %w[refused check length cwd]],
    relative_cwd: [F.start(BASE.merge(cwd: E.binary('home'))), %w[refused check text cwd]],
    tty_after_null: [F.start(BASE.merge(fds: E.list([E.tuple(E.small(0), E.atom('null')),
                                                     E.tuple(E.small(3), E.tuple(E.atom('tty'), E.small(1),
                                                                                 E.atom('read')))]))),
                     %w[refused descriptor 3]]
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-prog-startup-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  # Each hand-encoded fixture plans as its fields say: the check's verdict for a refused
  # one, the first descriptor other than null, or its argv, env and cwd.
  def test_the_hand_encoded_frames_plan_as_written
    answers = plans(F::ALL.map(&:bytes))
    F::ALL.zip(answers).each do |fixture, answer|
      got = answer_of(answer)
      got = got.slice(:argv, :env, :cwd) if got.is_a?(Hash)
      assert_equal expected_for(fixture), got, fixture.name.to_s
    end
  end

  def test_the_built_frames_plan_as_written
    plans(BUILT.values.map(&:first)).zip(BUILT).each do |answer, (name, (_frame, expected))|
      got = answer_of(answer)
      if expected.is_a?(Hash)
        assert_kind_of Hash, got, "#{name}: #{answer}"
        expected.each { |key, value| assert_equal value, got.fetch(key), "#{name}: #{key}" }
        assert_equal got.fetch(:argv).size.to_s, got.fetch(:argc), name.to_s
      else
        assert_equal expected, got, name.to_s
      end
    end
  end

  # The program profile names no frame to the program after the startup message.
  def test_a_later_frame_is_refused
    assert_equal ['later 127'], answers(['later'])
  end

  # Seeded faults: a plan that skips the check runs a frame the check refuses, from the
  # zeroed struct, and a cwd bound one short refuses the longest cwd the check accepts.
  def test_a_plan_without_the_check_runs_a_refused_frame
    seeded = seed(/if \(!erx_prog_check_start\(/, 'if (false && !erx_prog_check_start(')
    answer = plans([BUILT.fetch(:relative_cwd).first], seeded).first
    assert_equal %w[0 0], answer_of(answer).values_at(:pid, :data_area), answer
  end

  def test_a_cwd_bound_one_short_refuses_the_longest_cwd
    seeded = seed(/start\.cwd\.len >= sizeof\(out->cwd\)/, 'start.cwd.len >= sizeof(out->cwd) - 1')
    assert_equal ['refused bound'], plans([BUILT.fetch(:cwd_at_max).first], seeded)
  end

  private

  def expected_for(fixture)
    return ['refused', 'check', *fixture.verdict.split] unless fixture.verdict == 'accept'

    fields = fixture.fields.items.last
    other = fields.fetch(:fds).find { |entry| entry.items.last != :null }
    return ['refused', 'descriptor', other.items.first.to_s] if other

    { argv: fields.fetch(:argv), env: fields.fetch(:env), cwd: fields.fetch(:cwd) }
  end

  # An answer line as the words of a refusal, without its offset, or the go line's
  # argv, env and cwd with its other fields, each text decoded from hex.
  def answer_of(line)
    words = line.split
    return words.first(4) if words[0, 2] == %w[refused check]
    return words unless words.first == 'go'

    fields = words.drop(1).to_h { |word| word.split('=', 2).then { |key, value| [key.to_sym, value] } }
    texts = ->(key, count) { count.zero? ? [] : fields.fetch(key).split(':', -1).map { |hex| [hex].pack('H*') } }
    fields.merge(fds: fields.fetch(:fds).split(':'), argv: texts.call(:argv, Integer(fields.fetch(:argc))),
                 env: texts.call(:env, Integer(fields.fetch(:envc))), cwd: [fields.fetch(:cwd)].pack('H*'))
  end

  def plans(frames, sources = {}) = answers(frames.map { |bytes| "plan #{bytes.unpack1('H*')}" }, sources)

  # The driver's answers to requests, built from SOURCES with each source named in sources
  # replaced by the text it maps to.
  def answers(requests, sources = {})
    dir = Dir.mktmpdir('c', @directory)
    program = File.join(dir, 'driver')
    paths = SOURCES.map do |source|
      next File.join(ROOT, source) unless sources.key?(source)

      File.join(dir, File.basename(source)).tap { |path| File.binwrite(path, sources.fetch(source)) }
    end
    output, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), *CFLAGS, '-O1', '-g', *@flags,
                                     '-I', ROOT, '-I', File.join(ROOT, 'build/gen/include'),
                                     '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'kernel/crypto'),
                                     *paths, '-o', program, stdin_data: '')
    raise output unless status.success?

    File.write(File.join(dir, 'requests'), requests.map { |line| "#{line}\n" }.join)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', program, File.join(dir, 'requests'),
                                     stdin_data: '')
    raise output unless status.success?

    output.lines(chomp: true)
  end

  # PLAN's text with pattern replaced once, which must match.
  def seed(pattern, replacement)
    text = File.read(File.join(ROOT, PLAN))
    seeded = text.sub(pattern, replacement)
    raise "seed #{pattern.inspect} does not match" if seeded == text

    { PLAN => seeded }
  end
end
