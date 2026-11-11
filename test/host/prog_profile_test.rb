# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/prog_profile_frames'
require_relative '../fixtures/prog_profile_mutations'

# The program protocol's two checks over one corpus (docs/design-abi.md#program-protocol):
# liberx's C check, through test/fixtures/prog_profile_driver.c, and the generated Erlang
# grammar erx_prog_grammar, through test/erlang/erx_prog_profile_diff.erl, run on stock's
# emulator (ERX_ERL and ERX_ERLC). The corpus is that module's frames and mutations, the
# mutations test/fixtures/prog_profile_mutations.rb generates from the protocol's model,
# the hand-encoded fixtures and the C fuzz target's seeds. Their verdicts agree on every
# frame, their reason and kind on every single-rule mutation, each accepted frame written again from the C
# accessors decodes to the frame's own term, and half the promised scratch adds no
# refusal but scratch.
class ProgProfileTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  GRAMMAR = File.join(ROOT, 'build/gen/otp/erts/preloaded/src/erx_prog_grammar.erl')
  DIFF = File.join(ROOT, 'test/erlang/erx_prog_profile_diff.erl')
  SOURCES = %w[liberx/erx_profile.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
               kernel/crypto/blake3/blake3_portable.c build/gen/liberx/generated/prog_profile.c
               test/fixtures/prog_profile_driver.c].freeze
  CHECK = SOURCES[0]
  TABLE = SOURCES[4]
  PROTOCOL = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)).protocols
                            .find { |protocol| protocol.fetch(:name) == 'erx_prog' }
  MUTATIONS, SKIPPED = ProgProfileMutations.from(PROTOCOL)
  CFLAGS = %w[-std=c17 -Wall -Wextra -Werror -pedantic].freeze

  def setup
    @directory = Dir.mktmpdir('erx-prog-profile-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_both_checks_agree_and_the_accessors_write_the_frame_again
    rows = differential(File.binread(GRAMMAR))
    rows.each do |row|
      assert_equal row.fetch(:erlang).split.first, row.fetch(:c).split.first, row.inspect
      if row.fetch(:expected) == 'accept'
        assert_equal 'accepted same', row.fetch(:erlang), row.inspect
      else
        assert_equal "refused #{row.fetch(:expected)}", row.fetch(:c), row.inspect
        assert_equal "refused #{row.fetch(:expected)}", row.fetch(:erlang), row.inspect
      end
    end
  end

  # The check refuses scratch short of its promise before it walks the frame, after the frame bound.
  def test_half_the_scratch_is_refused_whole
    requests = corpus(File.binread(GRAMMAR)).fetch(:requests)
    full = c_answers(requests)
    half = c_answers(requests.map { |line| line.sub(' full ', ' half ') })
    full.zip(half).each do |whole, part|
      expected = whole.split[1, 2] == %w[refused size] ? whole : "#{whole.split.first} refused scratch"
      assert part.start_with?(expected), "#{whole} / #{part}"
    end
  end

  # Seeded faults: each breaks one check, and the test must see the two disagree.
  def test_a_table_with_the_cwd_bound_raised_disagrees
    seeded = seed(TABLE, /(\.name = "cwd",.*?\.text_max = )4096/m, '\14097')
    assert(disagreements(File.binread(GRAMMAR), seeded).any? { |row| row.fetch(:expected) == 'length cwd' })
  end

  def test_a_grammar_without_its_ascending_test_disagrees
    grammar = File.binread(GRAMMAR)
    seeded = grammar.gsub(/(list\(fun k_\w+\/2, V, [^,]+, )true/, '\1false')
    refute_equal grammar, seeded
    assert(disagreements(seeded).any? { |row| row.fetch(:expected).start_with?('order') })
  end

  def test_an_erlang_side_ignoring_used_disagrees
    @judge = 'judge_ignoring_used'
    rows = disagreements(File.binread(GRAMMAR))
    assert(rows.any? { |row| row.fetch(:expected) == 'malformed start' })
  end

  def test_text_views_one_byte_short_fail_the_round_trip
    seeded = seed(CHECK, '.len = len }', '.len = len > 0 ? len - 1 : 0 }')
    assert(disagreements(File.binread(GRAMMAR), seeded).any? { |row| row.fetch(:erlang) == 'accepted differs' })
  end

  # The hand-encoded frames of test/fixtures/prog_profile_frames.rb, each read by the C
  # check to the verdict and the fields written beside it.
  def test_the_hand_encoded_frames_read_as_written
    assert_empty fixture_mismatches
  end

  def test_a_check_refusing_big_integers_fails_the_capability_fixture
    seeded = seed(CHECK, "\t/* A big item holds", "\treturn (false);\n\t/* A big item holds")
    assert_includes fixture_mismatches(seeded), :cap_above_int64
  end

  def test_an_iterator_ending_at_its_first_segment_fails_the_segmented_fixture
    seeded = seed(CHECK, "\t\t/* The accepted list goes on in another segment. */\n",
                  "\t\t/* The accepted list goes on in another segment. */\n\t\treturn (false);\n")
    assert_includes fixture_mismatches(seeded), :segmented
  end

  # Each list's iterator is its own type: a view handed to another list's next fails to
  # compile, and one handed over by a cast is refused by the next's kind check.
  def test_one_lists_iterator_does_not_compile_as_anothers
    assert compiles?(crossing('erx_prog_argv_iter_t')), 'the control does not compile'
    refute compiles?(crossing('erx_prog_fds_iter_t')), "fds's iterator compiles as argv's"
  end

  def test_a_view_is_read_only_by_its_own_list
    assert(c_answers(fixture_requests).none? { |answer| answer.split[2] == 'crossed' })
  end

  def test_a_next_without_its_kind_check_reads_another_lists_view
    seeded = seed(CHECK, 'list->kind != kind', 'kind == ERX_PROFILE_NONE')
    assert(c_answers(fixture_requests, seeded).any? { |answer| answer.split[2] == 'crossed' })
  end

  # The generated table builds only against the bounds the generator assumed.
  def test_a_header_depth_bound_below_the_generators_fails_the_build
    assert compiles?(File.binread(File.join(ROOT, TABLE))), 'the table does not compile'
    header = File.binread(File.join(ROOT, 'include/erx/profile.h'))
    seeded = header.sub(/^(#define ERX_PROFILE_DEPTH_MAX\t)16$/, '\1' '15')
    refute_equal header, seeded
    refute compiles?(File.binread(File.join(ROOT, TABLE)), headers: { 'erx/profile.h' => seeded })
  end

  # The generated mutations name refusals the hand-written corpus does not, and skip only
  # the rules and kinds listed.
  def test_the_generated_mutations_reach_past_the_hand_written_ones
    hand = corpus(File.binread(GRAMMAR)).fetch(:hand).to_set
    assert_operator MUTATIONS.map(&:verdict).uniq.count { |verdict| !hand.include?(verdict) }, :>, 0
    assert_equal ['argv length', 'env length', 'request', 'signals length', 'writers length'],
                 SKIPPED.map { |line| line.split(':').first }.sort
  end

  private

  # The sources with path's text changed by one substitution, which must change it.
  def seed(path, pattern, replacement)
    text = File.binread(File.join(ROOT, path))
    seeded = text.sub(pattern, replacement)
    refute_equal text, seeded, "the seed does not apply to #{path}"
    { path => seeded }
  end

  def fixture_requests = ProgProfileFrames::ALL.map { |fixture| "start full #{fixture.bytes.unpack1('H*')}" }

  # The names of the fixtures whose C answer is not the verdict and fields written for them.
  def fixture_mismatches(sources = {})
    ProgProfileFrames::ALL.zip(c_answers(fixture_requests, sources)).reject do |fixture, answer|
      _, verdict, *rest = answer.split
      next rest.first(2).join(' ') == fixture.verdict if verdict == 'refused'

      verdict == 'accepted' && fixture.verdict == 'accept' && decoded(rest.first) == fixture.fields
    end.map { |fixture, _| fixture.name }
  end

  def decoded(hex)
    ProgProfileFrames::Etf.decode([hex].pack('H*'))
  rescue ArgumentError
    nil
  end

  def disagreements(grammar, sources = {})
    differential(grammar, sources).reject do |row|
      expected = row.fetch(:expected) == 'accept' ? 'accepted' : "refused #{row.fetch(:expected)}"
      row.fetch(:c) == expected && row.fetch(:erlang).sub(' same', '') == expected
    end
  end

  # Each frame's expected answer, the C verdict and the Erlang verdict, as
  # "accepted", "accepted same|differs" or "refused REASON KIND".
  def differential(grammar, sources = {})
    corpus = corpus(grammar)
    answers = c_answers(corpus.fetch(:requests), sources)
    judge = corpus.fetch(:requests).zip(answers).map do |request, answer|
      frame, _, hex = request.split
      rewrite = answer.split[2] if answer.split[1] == 'accepted' && answer.split[2].match?(/\A\h+\z/)
      [frame, hex, rewrite].compact.join(' ')
    end
    verdicts = erlang_verdicts(judge, grammar)
    corpus.fetch(:expected).zip(answers, verdicts).map do |expected, answer, verdict|
      wire, *c = answer.split
      c_verdict = c.first == 'accepted' ? 'accepted' : c.first(3).join(' ')
      frame = verdict.split.last
      verdict = "refused malformed #{frame}" if wire == 'nowire' && !verdict.start_with?('refused size')
      { expected: expected, c: c_verdict, erlang: verdict }
    end
  end

  def corpus(grammar)
    @corpus ||= {}
    @corpus[grammar] ||= begin
      dir = Dir.mktmpdir('corpus', @directory)
      erl(dir, grammar, 'corpus')
      seeds = ProgProfileFrames::SEEDS
      hand = File.readlines(File.join(dir, 'expected'), chomp: true) + ProgProfileFrames::ALL.map(&:verdict)
      { requests: File.readlines(File.join(dir, 'requests'), chomp: true) + fixture_requests +
          MUTATIONS.map { |mutation| "start full #{mutation.bytes.unpack1('H*')}" } +
          seeds.map { |seed| "#{seed.frame} full #{seed.bytes.unpack1('H*')}" },
        expected: hand + MUTATIONS.map(&:verdict) + seeds.map(&:verdict), hand: hand }
    end
  end

  def erlang_verdicts(lines, grammar)
    dir = Dir.mktmpdir('judge', @directory)
    File.write(File.join(dir, 'judge'), lines.map { |line| "#{line}\n" }.join)
    erl(dir, grammar, @judge || 'judge')
    File.readlines(File.join(dir, 'verdicts'), chomp: true)
  end

  def erl(dir, grammar, function)
    File.binwrite(File.join(dir, 'erx_prog_grammar.erl'), grammar)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', dir, File.join(dir, 'erx_prog_grammar.erl'), DIFF,
                                     stdin_data: '')
    raise output unless status.success?

    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', dir,
                                     '-run', 'erx_prog_profile_diff', function, dir, chdir: dir, stdin_data: '')
    raise output unless status.success?
  end

  # The C driver's answers to requests, built from SOURCES with each source named in
  # sources replaced by the text it maps to.
  def c_answers(requests, sources = {})
    dir = Dir.mktmpdir('c', @directory)
    program = File.join(dir, 'driver')
    sources = SOURCES.map do |source|
      next File.join(ROOT, source) unless sources.key?(source)

      File.join(dir, File.basename(source)).tap { |path| File.binwrite(path, sources.fetch(source)) }
    end
    output, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), *CFLAGS, '-O1', '-g', *@flags, '-I', File.join(ROOT, 'build/gen/include'),
                                     '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'kernel/crypto'),
                                     *sources, '-o', program, stdin_data: '')
    raise output unless status.success?

    File.write(File.join(dir, 'requests'), requests.map { |line| "#{line}\n" }.join)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', program, File.join(dir, 'requests'),
                                     File.join(dir, 'answers'), stdin_data: '')
    raise output unless status.success?

    File.readlines(File.join(dir, 'answers'), chomp: true)
  end

  # A translation unit that hands an iterator of type to argv's next.
  def crossing(type)
    "#include <erx/prog_profile.h>\n" \
      "bool crossed(#{type} *it, erx_profile_text_t *t);\n" \
      "bool\ncrossed(#{type} *it, erx_profile_text_t *t)\n{\n\treturn (erx_prog_argv_next(it, t));\n}\n"
  end

  # Whether source compiles, with headers (an include path => its text) ahead of the tree's.
  def compiles?(source, headers: {})
    dir = Dir.mktmpdir('compile', @directory)
    headers.each do |name, text|
      FileUtils.mkdir_p(File.join(dir, File.dirname(name)))
      File.binwrite(File.join(dir, name), text)
    end
    File.binwrite(File.join(dir, 'unit.c'), source)
    _, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), *CFLAGS, '-fsyntax-only', '-I', dir,
                                '-I', File.join(ROOT, 'build/gen/include'), '-I', File.join(ROOT, 'include'),
                                File.join(dir, 'unit.c'), stdin_data: '')
    status.success?
  end
end
