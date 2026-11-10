# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/erx_net_host'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The network stack's per-byte primitives, erx_bytes:inet_csum/2, inet_csum_update/3 and
# siphash24/2 (docs/design-runtime.md, "Per-byte primitives"), in their C cores
# (erlang/apps/erx_net/c_src/erx_inet_csum.c and erx_siphash.c), which erXos's ERTS links into
# its erx_bytes BIFs and the portable erx_bytes loads as erx_net's priv/erx_bytes_nif.so:
# * each core's harness (test/fixtures/erx_*_harness.c) passes the published examples and
#   vectors, its cuts and its model under the address and undefined sanitizers, and fails for
#   every mutant, each changing one expression of the core;
# * each fuzz target is declared over its core (the iodata walk's over
#   erlang/apps/erx_net/c_src/erx_iodata.c), its seeds pass, and they catch a seeded fault;
# * the cores agree with the Erlang models of the host stand-in
#   (test/erlang/host_bytes/erx_bytes.erl) over random cases, through
#   test/fixtures/erx_bytes_cases.c and test/erlang/erx_bytes_cases.erl, and the models pass
#   their EUnit cases (test/erlang/erx_bytes_tests.erl, with the contract of
#   test/fixtures/erx_net_bytes_probe.erl) on stock's emulator (ERX_ERL and ERX_ERLC, which
#   make check supplies);
# * the portable erx_bytes (erlang/apps/erx_net/portable/erx_bytes.erl) over the library
#   that c_src/Makefile builds passes the same EUnit cases, answers the random cases and
#   the probe's calls as the models do, fails its EUnit cases for a seeded fault in each
#   primitive's NIF function, and without its library refuses every call instead of
#   answering one.
class ErxNetBytesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  C_SRC = File.join(ROOT, 'erlang/apps/erx_net/c_src')
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-fno-omit-frame-pointer',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  MODEL = File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl')
  PORTABLE = File.join(ROOT, 'erlang/apps/erx_net/portable/erx_bytes.erl')
  CASES = %w[test/erlang/erx_bytes_cases.erl test/erlang/erx_bytes_tests.erl
             test/fixtures/erx_net_bytes_probe.erl].map { |path| File.join(ROOT, path) }.freeze
  RANDOM_CASES = 600
  EUNIT = 'halt(case eunit:test([erx_bytes_tests], [verbose]) of ok -> 0; _ -> 1 end)'

  # A seeded fault in each primitive's NIF function (c_src/erx_bytes_nif.c) and in the iodata
  # walk under them (c_src/erx_iodata.c): the file, the text it replaces and the faulty text.
  NIF_FAULTS = {
    'inet_csum: a piece at an odd offset summed as at an even one' =>
      ['erx_bytes_nif.c', '*sum = erx_inet_sum(*sum, data, length, before);',
       '*sum = erx_inet_sum(*sum, data, length, before & ~(size_t)1);'],
    'inet_csum_update: the bytes before and after swapped' =>
      ['erx_bytes_nif.c', '(uint16_t)checksum, before.data, after.data,', '(uint16_t)checksum, after.data, before.data,'],
    'siphash24: the last byte of each piece dropped' =>
      ['erx_bytes_nif.c', 'erx_siphash24_update(context, data, length);',
       'erx_siphash24_update(context, data, length - (length > 0));'],
    'walk: one cell over the limit taken' =>
      ['erx_iodata.c', 'if (++walk->cells > ERX_IODATA_CELLS_MAX)', 'if (++walk->cells > ERX_IODATA_CELLS_MAX + 1)'],
    'walk: an integer tail taken as a byte' =>
      ['erx_iodata.c', "\t\tcase ERX_IODATA_BYTE:\n\t\tcase ERX_IODATA_OTHER:\n\t\t\treturn (ERX_IODATA_BADARG);",
       "\t\tcase ERX_IODATA_BYTE:\n\t\t\tif (!take_byte(walk, item.value))\n\t\t\t\treturn (ERX_IODATA_BADARG);\n\t\t\tbreak;\n" \
       "\t\tcase ERX_IODATA_OTHER:\n\t\t\treturn (ERX_IODATA_BADARG);"],
    'walk: the last run of integer bytes never visited' =>
      ['erx_iodata.c', "\tif (status == ERX_IODATA_OK)\n\t\tflush_run(&walk);\n", '']
  }.freeze

  Core = Data.define(:kind, :source, :harness, :done, :mutants, :fuzz_catches)

  CORES = [
    Core.new(
      kind: 'inet_csum', source: 'erx_inet_csum.c', harness: 'erx_inet_csum_harness.c', done: 'erx_inet_csum done',
      mutants: {
        'a single fold' => ['while (total > 0xffffu)', 'if (total > 0xffffu)'],
        'odd start not swapped' => ["if (offset % 2 != 0)\n\t\tpiece = swap(piece);", '(void)offset;'],
        'last odd byte in the low half' => ['total += (uint64_t)data[i] << 8;', 'total += data[i];'],
        'update adds the words before' => ['total += 0xffffu ^ (', 'total += 0x0000u ^ ('],
        'update skips the last word' => ['for (i = 0; i + 1 < length; i += 2) {', 'for (i = 0; i + 3 < length; i += 2) {'],
        'update takes the field uncomplemented' => ['uint64_t total = (uint16_t)~checksum;', 'uint64_t total = checksum;'],
        'copy: the carry not wrapped' => ["\t\ttotal += total < word;\n", ''],
        'copy: no swap on a little-endian host' => ["#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__\n\tpiece = swap(piece);\n#endif\n", ''],
        'copy: the last odd byte dropped' => ["\tfor (; i < length; i++) {", "\tfor (; i + 1 < length; i++) {"],
        'copy: a word read past the end' => ['length - i >= sizeof(word)', 'length - i + 1 >= sizeof(word)'],
        'copy: odd start not swapped' => ["\tpiece = fold(piece + tail);\n\tif (offset % 2 != 0)\n\t\tpiece = swap(piece);",
                                          "\tpiece = fold(piece + tail);\n\t(void)offset;"],
        'copy: a tail byte in the wrong half' => ['tail += i % 2 == 0 ? (uint64_t)byte << 8 : byte;',
                                                  'tail += i % 2 == 1 ? (uint64_t)byte << 8 : byte;']
      },
      fuzz_catches: ['odd start not swapped', 'update skips the last word', 'copy: no swap on a little-endian host',
                     'copy: the last odd byte dropped']
    ),
    Core.new(
      kind: 'siphash', source: 'erx_siphash.c', harness: 'erx_siphash_harness.c', done: 'erx_siphash done',
      mutants: {
        'a rotation off by one' => ['v[1] = ROTL(v[1], 13);', 'v[1] = ROTL(v[1], 12);'],
        'no finishing constant' => ['v[2] ^= 0xffu;', 'v[2] ^= 0u;'],
        'three finishing rounds' => ['rounds(v, 4);', 'rounds(v, 3);'],
        'length byte cut to seven bits' => ['(state->length & 0xffu) << 56', '(state->length & 0x7fu) << 56'],
        'a completed pending word dropped' => ['compress(state->v, load64(state->pending));', ';'],
        'key halves swapped' => ['uint64_t k0 = load64(key), k1 = load64(key + 8);',
                                 'uint64_t k1 = load64(key), k0 = load64(key + 8);']
      },
      fuzz_catches: ['length byte cut to seven bits', 'a completed pending word dropped']
    )
  ].freeze

  # The iodata walk under the NIFs and erXos's BIFs (c_src/erx_iodata.c), which has no harness of
  # its own: the EUnit cases judge it through the portable library (NIF_FAULTS), and its fuzz
  # target judges it against a model of its own.
  WALK = Core.new(
    kind: 'iodata', source: 'erx_iodata.c', harness: nil, done: nil,
    mutants: {
      'a tail kept for later dropped' => ["\twalk->stack[walk->depth++] = tail;", "\twalk->stack[walk->depth++] = tail & 0;"],
      'the stack copied short when it moves' => ['bcopy(walk->local, grown, sizeof(walk->local));',
                                                 'bcopy(walk->local, grown, sizeof(walk->local) / 2);'],
      'a binary of exactly the room left refused' => [
        'walk->layer->classify(walk->layer->env, cell->head, ERX_BYTES_CALL_MAX - walk->bytes, &head);',
        'walk->layer->classify(walk->layer->env, cell->head, ERX_BYTES_CALL_MAX - walk->bytes - 1, &head);'
      ]
    },
    fuzz_catches: ['a tail kept for later dropped', 'the stack copied short when it moves',
                   'a binary of exactly the room left refused']
  )

  def test_each_harness_passes
    CORES.each do |core|
      Dir.mktmpdir("erx-#{core.kind}-") do |directory|
        output, status = build_and_run(directory, core, File.join(C_SRC, core.source))
        assert status.success?, output
        assert_match(/^#{core.done}$/, output)
      end
    end
  end

  def test_every_mutant_fails_its_harness
    CORES.each do |core|
      core.mutants.each do |name, (original, replacement)|
        Dir.mktmpdir("erx-#{core.kind}-mutant-") do |directory|
          output, status = build_and_run(directory, core, mutate(directory, core, original, replacement))
          refute status.success?, "#{core.kind} mutant survived the harness: #{name}"
          refute_match(/#{core.done}/, output)
        end
      end
    end
  end

  def test_each_fuzz_target_declares_its_core_and_its_seeds_pass
    [*CORES, WALK].each do |core|
      Dir.mktmpdir("erx-#{core.kind}-fuzz-") do |directory|
        output, status = run_fuzz(directory, core, File.join(C_SRC, core.source))
        assert status.success?, output
      end
    end
  end

  def test_each_fuzz_target_catches_its_seeded_faults
    [*CORES, WALK].each do |core|
      core.fuzz_catches.each do |name|
        original, replacement = core.mutants.fetch(name)
        Dir.mktmpdir("erx-#{core.kind}-fuzz-mutant-") do |directory|
          _output, status = run_fuzz(directory, core, mutate(directory, core, original, replacement))
          refute status.success?, "the #{core.kind} fuzz target did not catch the seeded fault: #{name}"
        end
      end
    end
  end

  def test_the_cores_agree_with_the_erlang_models
    Dir.mktmpdir('erx-net-bytes-diff-') do |directory|
      cases = File.join(directory, 'cases.txt')
      File.write(cases, random_cases(Random.new(1071)).join("\n") << "\n")
      c_answers = c_answers(directory, cases)
      erlang_answers = erlang_answers(directory, cases)
      assert_equal RANDOM_CASES, c_answers.size
      c_answers.zip(erlang_answers, File.readlines(cases, chomp: true)).each do |c, erlang, line|
        assert_equal c, erlang, "the C core and the Erlang model differ on: #{line[0, 200]}"
      end
    end
  end

  def test_the_erlang_models_pass_their_eunit_cases
    Dir.mktmpdir('erx-net-bytes-eunit-') do |directory|
      compile_erlang(directory, MODEL)
      output, status = run_erlang(directory, EUNIT)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_the_portable_nif_passes_the_eunit_cases
    Dir.mktmpdir('erx-net-bytes-nif-') do |work|
      output, status = run_erlang(nif_ebin(work), EUNIT)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # The random cases, whose iolists nest pieces of every length at odd and even offsets, and
  # the probe's calls (test/fixtures/erx_net_bytes_probe.erl): the models answer in one node,
  # and the portable erx_bytes over its library must answer alike in another.
  def test_the_portable_nif_answers_as_the_models_do
    Dir.mktmpdir('erx-net-bytes-nif-diff-') do |work|
      cases = File.join(work, 'cases.txt')
      File.write(cases, random_cases(Random.new(1624)).join("\n") << "\n")
      model = File.join(work, 'model').tap { |directory| FileUtils.mkdir_p(directory) }
      nif = nif_ebin(work)
      model_answers = erlang_answers(model, cases)
      assert_equal RANDOM_CASES, model_answers.size
      model_answers.zip(answer_cases(nif, cases), File.readlines(cases, chomp: true)).each do |want, got, line|
        assert_equal want, got, "the portable NIF and the Erlang model differ on: #{line[0, 200]}"
      end
      probe = File.join(work, 'probe.etf')
      output, status = run_erlang(model, "ok = file:write_file(\"#{probe}\", " \
                                         'term_to_binary(erx_net_bytes_probe:answers())), halt().')
      assert status.success?, output
      output, status = run_erlang(nif, "{ok, B} = file:read_file(\"#{probe}\"), " \
                                       'io:format("~p~n", [erx_net_bytes_probe:check(binary_to_term(B))]), halt().')
      assert status.success?, output
      assert_equal '{net_bytes,[],[]}', output.strip
    end
  end

  # A binary at a bit offset is copied whole by enif_inspect_binary, so each argument the
  # portable library inspects must be refused, when it is large, before it reaches the NIF.
  # The probe refuses a 32 MiB one in every argument position and reports whether any
  # temporary block (temp_alloc's largest single-block carrier yet) reached its size.
  def test_the_portable_nif_refuses_a_large_bit_offset_binary_without_copying_it
    Dir.mktmpdir('erx-net-bytes-nif-copy-') do |work|
      output, status = run_erlang(nif_ebin(work), <<~ERLANG.tr("\n", ' '))
        Size = 32 bsl 20,
        <<_:1, Big/binary>> = <<0:1, 0:(Size * 8)>>,
        Calls = [fun() -> erx_bytes:inet_csum(0, Big) end,
                 fun() -> erx_bytes:inet_csum(0, [<<1>>, Big]) end,
                 fun() -> erx_bytes:inet_csum_update(0, Big, Big) end,
                 fun() -> erx_bytes:siphash24(Big, <<>>) end,
                 fun() -> erx_bytes:siphash24(<<0:128>>, [Big]) end],
        Refusals = [catch Call() || Call <- Calls],
        Peaks = [Max || {instance, _, Info} <- erlang:system_info({allocator, temp_alloc}),
                        {sbcs, Carriers} <- [lists:keyfind(sbcs, 1, Info)],
                        {carriers_size, _, _, Max} <- Carriers],
        io:format("~p~n", [{[Reason || {'EXIT', {Reason, _}} <- Refusals], Peaks =/= [], lists:max([0 | Peaks]) < Size}]),
        halt().
      ERLANG
      assert status.success?, output
      # The middle true says temp_alloc reported its single-block carrier statistics in the
      # shape the probe reads, so a change of that shape cannot pass the size check vacuously.
      assert_equal '{[badarg,badarg,badarg,badarg,badarg],true,true}', output.strip
    end
  end

  # The size check before the NIF stops near where the walk does: a list that shares its halves
  # 60 deep, 2^60 cells walked whole, is refused within seconds, not walked. Each calling
  # process builds the list and sends back only the reason, since a closure or a message that
  # held the list would copy it unshared.
  def test_the_portable_size_check_stops_at_the_cell_limit
    Dir.mktmpdir('erx-net-bytes-nif-cells-') do |work|
      output, status = run_erlang(nif_ebin(work), <<~ERLANG.tr("\n", ' '))
        Doubled = fun() -> lists:foldl(fun(_, Half) -> [Half, Half] end, [], lists:seq(1, 60)) end,
        Self = self(),
        Calls = [fun(List) -> erx_bytes:inet_csum(0, List) end,
                 fun(List) -> erx_bytes:siphash24(<<0:128>>, List) end],
        Reason = fun(Call) -> case catch Call(Doubled()) of {'EXIT', {Why, _}} -> Why; Value -> Value end end,
        [spawn(fun() -> Self ! {Index, Reason(Call)} end) || {Index, Call} <- lists:enumerate(Calls)],
        Answers = [receive {Index, Answer} -> Answer after 5000 -> timeout end
                   || Index <- lists:seq(1, length(Calls))],
        io:format("~p~n", [Answers]),
        halt().
      ERLANG
      assert status.success?, output
      assert_equal '[badarg,badarg]', output.strip
    end
  end

  def test_every_seeded_nif_fault_fails_the_eunit_cases
    NIF_FAULTS.each do |name, (file, exact, faulty)|
      Dir.mktmpdir('erx-net-bytes-nif-fault-') do |work|
        c_src = File.join(work, 'c_src')
        FileUtils.cp_r(C_SRC, c_src)
        functions = File.join(c_src, file)
        source = File.read(functions)
        raise "seeded fault site is gone: #{exact}" unless source.include?(exact)

        File.write(functions, source.sub(exact) { faulty })
        output, status = run_erlang(nif_ebin(File.join(work, 'run'), c_src: c_src), EUNIT)
        refute status.success?, "a seeded fault passed the portable NIF's EUnit cases: #{name}"
        assert_match(/Failed: [1-9]/, output, name)
      end
    end
  end

  # No library in priv/: the module does not load, so every call, entropy/1's included,
  # fails with undef, and the reason is in the node's log; no call answers from Erlang.
  def test_without_its_library_the_portable_module_refuses_every_call
    Dir.mktmpdir('erx-net-bytes-nolib-') do |work|
      ebin = File.join(work, 'erx_net', 'ebin')
      FileUtils.mkdir_p([ebin, File.join(work, 'erx_net', 'priv')])
      compile_erlang(ebin, PORTABLE)
      calls = 'fun() -> erx_bytes:inet_csum(0, <<1, 2>>) end, fun() -> erx_bytes:inet_csum_update(0, <<>>, <<>>) end, ' \
              'fun() -> erx_bytes:siphash24(<<0:128>>, <<>>) end, fun() -> erx_bytes:entropy(1) end'
      output, status = run_erlang(ebin, "io:format(\"~p~n\", [[try F() of V -> {value, V} catch C:R -> {C, R} end " \
                                        "|| F <- [#{calls}]]]), halt().")
      assert status.success?, output
      assert_includes output.lines(chomp: true), '[{error,undef},{error,undef},{error,undef},{error,undef}]'
      assert_match(/erx_bytes_nif/, output)
    end
  end

  private

  # Random cases of erx_bytes_cases.c's format: inputs cut into up to five pieces of any
  # length, some all ff or all zero, and updates whose words before and after are either.
  def random_cases(random)
    fills = [->(n) { random.bytes(n) }, ->(n) { "\xff".b * n }, ->(n) { "\0".b * n }]
    hex = ->(bytes) { bytes.empty? ? '-' : bytes.unpack1('H*') }
    pieces = lambda do
      bytes = fills.sample(random: random).call([0, 1, 2, 7, 64, 1500, 9001].sample(random: random))
      cuts = Array.new(random.rand(5)) { random.rand(bytes.size + 1) }.sort
      [0, *cuts, bytes.size].each_cons(2).map { |from, to| hex.call(bytes.byteslice(from, to - from)) }
    end
    Array.new(RANDOM_CASES) do |index|
      case index % 3
      when 0 then ['sum', format('%x', random.rand(0x10000)), *pieces.call].join(' ')
      when 1
        size = 2 * random.rand(5)
        ['update', format('%x', random.rand(0x10000)),
         *Array.new(2) { hex.call(fills.sample(random: random).call(size)) }].join(' ')
      else ['sip', hex.call(random.bytes(16)), *pieces.call].join(' ')
      end
    end
  end

  def c_answers(directory, cases)
    program = File.join(directory, 'cases')
    output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', C_SRC,
                                     File.join(ROOT, 'test/fixtures/erx_bytes_cases.c'),
                                     File.join(C_SRC, 'erx_inet_csum.c'), File.join(C_SRC, 'erx_siphash.c'),
                                     '-o', program, stdin_data: '')
    assert status.success?, output
    output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program,
                                     stdin_data: File.read(cases))
    assert status.success?, output
    output.lines(chomp: true)
  end

  def erlang_answers(directory, cases)
    compile_erlang(directory, MODEL)
    answer_cases(directory, cases)
  end

  def answer_cases(directory, cases)
    output, status = run_erlang(directory, "erx_bytes_cases:answer(\"#{cases}\"), halt().")
    assert status.success?, output
    output.lines(chomp: true)
  end

  # The cases' modules into directory with implementation, the model or the portable module.
  def compile_erlang(directory, implementation)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', directory, implementation, *CASES,
                                     stdin_data: '')
    assert status.success?, output
  end

  # erx_net laid out in work with the library built from c_src, and the portable erx_bytes
  # compiled into its ebin with the cases' modules; the ebin.
  def nif_ebin(work, c_src: C_SRC)
    Erx::ErxNetHost.lay_out(work, erl: ENV.fetch('ERX_ERL'), c_src: c_src).tap { |ebin| compile_erlang(ebin, PORTABLE) }
  end

  def run_erlang(directory, expression)
    Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', directory,
                    '-eval', expression, chdir: directory, stdin_data: '')
  end

  def mutate(directory, core, original, replacement)
    source = File.read(File.join(C_SRC, core.source))
    raise "mutation site is gone: #{original}" unless source.include?(original)

    path = File.join(directory, core.source)
    File.write(path, source.sub(original) { replacement })
    path
  end

  def build_and_run(directory, core, source)
    program = File.join(directory, 'harness')
    output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', C_SRC,
                                     File.join(ROOT, 'test/fixtures', core.harness), source, '-o', program,
                                     stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, stdin_data: '')
  end

  # Builds the fuzz program with the gate's own command, source standing in for the target's
  # core, and runs it once over the target's seeds.
  def run_fuzz(directory, core, source)
    target = Erx::PackFuzz.targets.find { |candidate| candidate.kind == core.kind }
    refute_nil target, "#{core.kind} fuzz target is not declared"
    core_path = File.join(C_SRC, core.source)
    assert_equal [core_path.delete_prefix("#{ROOT}/")], target.sources
    corpus = File.join(directory, 'corpus')
    FileUtils.mkdir_p(corpus)
    target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(directory, 'fuzz')
    command = Erx::PackFuzz.compile_command(target, root: ROOT, compiler: COMPILER, program: program)
    command = command.map { |argument| argument == core_path ? source : argument }
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, '-runs=0', corpus,
                    stdin_data: '', chdir: directory)
  end
end
