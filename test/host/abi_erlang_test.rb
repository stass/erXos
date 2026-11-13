# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi_emit_erlang'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/json_input'
require_relative '../fixtures/abi_manifest_fixture'
require_relative '../fixtures/abi_erlang_fixture'

class AbiErlangTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-abi-erlang-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'),
                              timeout_program: 'gtimeout')
    @oracle = File.join(@root, 'build/oracle/jit/install/bin')
    receipt_path = File.join(@root, 'build/oracle/jit/build.json')
    receipt = Erx::JsonInput.parse(File.binread(receipt_path), max_bytes: 1_048_576,
                                   label: 'stock OTP receipt')
    unless receipt.fetch('version') == '29.1.2' && receipt.fetch('state') == 'ready' &&
           receipt.fetch('flavour') == 'jit' &&
           receipt.fetch('source_sha256') == 'c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049'
      raise Erx::Error, 'generated Erlang reader requires the verified stock OTP 29.1.2 JIT build'
    end
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: @root))
    @codec = Erx::ABI::Codec.new(schema)
    outputs = Erx::ABI::ErlangEmitter.outputs(schema)
    outputs.each do |path, bytes|
      File.binwrite(File.join(@directory, File.basename(path)), bytes)
    end
    @environment = { 'ERL_AFLAGS' => nil, 'ERL_FLAGS' => nil, 'ERL_ZFLAGS' => nil,
                     'ERL_LIBS' => nil, 'ERL_ROOTDIR' => nil, 'ROOTDIR' => nil }
    @runner.run([File.join(@oracle, 'erlc'), '-Werror', '-I', @directory, '-o', @directory,
                 File.join(@directory, 'erx_manifest.erl'),
                 File.join(@root, 'test/fixtures/erx_abi_reader_tests.erl')],
                name: 'erlc', deadline: 60, env: @environment)
    File.binwrite(File.join(@directory, 'valid.bin'), AbiManifestFixture.valid)
    write_partition_and_parameter_fixtures
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && @directory && File.directory?(@directory)
  end

  def run_oracle(function, argument)
    record = @runner.run([File.join(@oracle, 'erl'), '+S', '1:1', '+SDcpu', '1',
                          '+SDio', '1', '-noshell', '-noinput', '-pa', @directory,
                          '-s', 'erx_abi_reader_tests', function, '-extra', argument],
                         name: function, deadline: 60, env: @environment)
    File.binread(record.fetch('log'))
  end

  def test_generated_reader_passes_stock_otp_eunit
    output = run_oracle('run', @directory)
    assert_includes output, 'All 9 tests passed.'
  end

  def test_generated_erlang_values_match_independent_bytes_and_ruby_reader
    output = run_oracle('inspect', File.join(@directory, 'valid.bin'))
    decoded = Erx::JsonInput.parse(output, max_bytes: 1_048_576, label: 'Erlang reader projection')
    view = @codec.open('manifest', AbiManifestFixture.valid)
    assert_equal '6f6b', decoded.fetch('status').fetch('bytes')
    assert_equal view.header, decode_json_values(decoded.fetch('header'))
    principal = view.fetch('principals', 0)
    assert_equal principal, decode_json_values(decoded.fetch('principal'))
    assert_equal 'root', decode_json_values(decoded.fetch('principal_name'))
  end

  def test_production_fuzz_entry_refuses_mutations_without_vm_exception
    directory = File.join(@directory, 'corpus')
    FileUtils.mkdir_p(directory)
    valid = AbiManifestFixture.valid
    corpus = [valid, ''.b, "\xff".b * valid.bytesize]
    corpus.concat(Dir.glob(File.join(@directory, '*.bin')).sort.map { |path| File.binread(path) })
    (0...valid.bytesize).step(13) do |offset|
      changed = valid.dup
      changed.setbyte(offset, changed.getbyte(offset) ^ 0xff)
      corpus << changed
      corpus << valid.byteslice(0, offset)
    end
    random = Random.new(0x455258)
    512.times do
      length = random.rand(0..1024)
      corpus << Array.new(length) { random.rand(0..255) }.pack('C*')
    end
    corpus.each_with_index do |bytes, index|
      File.binwrite(File.join(directory, format('%05d.bin', index)), bytes)
    end
    output = run_oracle('fuzz', directory)
    assert_equal "checked #{corpus.size} reader inputs\n", output
  end

  # erx_abi.hrl lists each enum's members in value order, on one line or
  # wrapped, and both forms compile and read as the ABI file declares them.
  def test_generated_enum_members_list_each_member_in_value_order
    File.binwrite(File.join(@directory, 'erx_abi_members.erl'), <<~ERLANG)
      -module(erx_abi_members).
      -export([main/0]).
      -include("erx_abi.hrl").
      main() ->
          io:format("~w~n~w~n", [?ERX_WINDOWS_FILE_MEMBERS, ?ERX_MF_WINDOW_ROLE_MEMBERS]),
          halt().
    ERLANG
    @runner.run([File.join(@oracle, 'erlc'), '-Werror', '-I', @directory, '-o', @directory,
                 File.join(@directory, 'erx_abi_members.erl')],
                name: 'erlc-members', deadline: 60, env: @environment)
    record = @runner.run([File.join(@oracle, 'erl'), '-noshell', '-noinput', '-pa', @directory,
                          '-s', 'erx_abi_members', 'main'], name: 'members', deadline: 60, env: @environment)
    roles = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: @root)).types.fetch('mf_window_role')
                           .members.sort_by { |_name, value| value }
                           .map { |name, value| "{#{name},#{value}}" }.join(',')
    assert_equal "[{ctl,1},{mouse,2},{kbd,3},{wctl,4},{label,5}]\n[#{roles}]\n", File.binread(record.fetch('log'))
  end

  # The generated erx_abi_events gives each trace event's name and typed
  # arguments, and unknown for a value trace_event does not hold.
  def test_generated_events_describe_each_trace_event
    @runner.run([File.join(@oracle, 'erlc'), '-Werror', '-o', @directory,
                 File.join(@directory, 'erx_abi_events.erl')], name: 'erlc-events', deadline: 60, env: @environment)
    script = 'io:format("~w~n", [[erx_abi_events:describe(trace_event, V) || V <- lists:seq(0, 6)]]), ' \
             'io:format("~w~n", [{erx_abi_events:status(-12), erx_abi_events:status(1), ' \
             'erx_abi_events:flags(trace_record_flags), erx_abi_events:flags(trace_event)}]), halt().'
    record = @runner.run([File.join(@oracle, 'erl'), '+S', '1:1', '+SDcpu', '1', '+SDio', '1', '-noshell',
                          '-noinput', '-pa', @directory, '-eval', script], name: 'events', deadline: 60, env: @environment)
    expected = '[unknown,{park,[{slot,u64},{deadline,u64}]},{wake,[{slot,u64},{result,status}]},' \
               '{irq_deliver,[{label,u64}]},{space_start,[{target,u64}]},' \
               "{space_end,[{target,u64},{status,i64}]},unknown]\n{notsup,unknown,[{cpu_unknown,1}],[]}\n"
    assert_equal expected, File.binread(record.fetch('log'))
  end

  # The generated erx_abi_signals maps each protocol name to its number and
  # default action and back, and gives unknown for a reserved or unlisted
  # number and an atom that names no signal.
  def test_generated_signals_map_names_numbers_and_actions
    @runner.run([File.join(@oracle, 'erlc'), '-Werror', '-o', @directory,
                 File.join(@directory, 'erx_abi_signals.erl')], name: 'erlc-signals', deadline: 60, env: @environment)
    script = 'io:format("~w~n", [[erx_abi_signals:name(N) || N <- [0, 17, 29, 32, 64, 65, 66, 96, 126, 127]]]), ' \
             "io:format(\"~w~n\", [[erx_abi_signals:number(A) || A <- [sigusr1, 'sigrtmax-1', sigiot, usr1]]]), " \
             'io:format("~w~n", [[erx_abi_signals:default_action(A) || A <- [sigcont, sigio, sigtstp, sigthr]]]), halt().'
    record = @runner.run([File.join(@oracle, 'erl'), '+S', '1:1', '+SDcpu', '1', '+SDio', '1', '-noshell',
                          '-noinput', '-pa', @directory, '-eval', script], name: 'signals', deadline: 60, env: @environment)
    expected = "[unknown,sigstop,siginfo,unknown,unknown,sigrtmin,'sigrtmin+1','sigrtmax-30',sigrtmax,unknown]\n" \
               "[30,125,unknown,unknown]\n[continue,ignore,stop,unknown]\n"
    assert_equal expected, File.binread(record.fetch('log'))
  end

  # erx_prog:status/1 over every kind of end (docs/design-programs.md, "A
  # program's end"): ERX_EXIT_SIGNAL + N for N from 0 to 255 is signaled
  # with the name erx_abi_signals gives N, or exited 255 where it gives
  # none; a halt 0 to 255 is exited with it; ERX_EXIT_PARENT is signaled
  # sigkill; each fault kind gives its fault table's signal; and every other
  # status, the kernel's nothread and released, crash and a fault record of
  # no fault kind, exit's included, is exited 255.
  def test_generated_status_reads_every_end
    @runner.run([File.join(@oracle, 'erlc'), '-Werror', '-o', @directory,
                 File.join(@directory, 'erx_abi_signals.erl'), File.join(@directory, 'erx_prog.erl')],
                name: 'erlc-status', deadline: 60, env: @environment)
    script = <<~ERLANG.tr("\n", ' ')
      Signals = [erx_prog:status(256 + N) =:= case erx_abi_signals:name(N) of
                                                  unknown -> {exited, 255};
                                                  Name -> {signaled, Name}
                                              end || N <- lists:seq(0, 255)],
      Halts = [erx_prog:status(N) =:= {exited, N} || N <- lists:seq(0, 255)],
      io:format("~w ~w~n", [lists:usort(Signals), lists:usort(Halts)]),
      io:format("~w~n", [[erx_prog:status(S) || S <- [256 + 11, 256 + 33, 256 + 66, 256 + 126, -1, 512,
                          -9223372036854775807, -9223372036854775806, -9223372036854775805,
                          -9223372036854775804]]]),
      io:format("~w~n", [[erx_prog:status({fault, K}) || K <- lists:seq(0, 10)]]),
      halt().
    ERLANG
    record = @runner.run([File.join(@oracle, 'erl'), '+S', '1:1', '+SDcpu', '1', '+SDio', '1', '-noshell',
                          '-noinput', '-pa', @directory, '-eval', script], name: 'status', deadline: 60, env: @environment)
    expected = "[true] [true]\n" \
               "[{signaled,sigsegv},{exited,255},{signaled,'sigrtmin+1'},{signaled,sigrtmax},{exited,255}," \
               "{exited,255},{signaled,sigkill},{exited,255},{exited,255},{exited,255}]\n" \
               '[{exited,255},{signaled,sigsegv},{signaled,sigbus},{signaled,sigill},{signaled,sigbus},' \
               '{signaled,sigtrap},{signaled,sigsys},{signaled,sigbus},{signaled,sigkill},{exited,255},' \
               "{exited,255}]\n"
    assert_equal expected, File.binread(record.fetch('log'))
  end

  private

  def write_partition_and_parameter_fixtures
    valid = AbiErlangFixture.devices(owners: 2, devices: 2)
    overlapping = valid.dup
    AbiManifestFixture.integer(overlapping, 732, 744)
    # The one unit claims the second device row, leaving the first unclaimed.
    gap = AbiErlangFixture.devices(owners: 1, devices: 2)
    AbiManifestFixture.integer(gap, 708, 720 + AbiManifestFixture::DEVICE_ROW)
    fixtures = {
      'partition_valid' => valid,
      'partition_overlap' => overlapping,
      'partition_gap' => gap,
      'partition_orphan' => AbiErlangFixture.devices(owners: 1, devices: 2),
      'bool_valid' => AbiErlangFixture.parameter(kind: 3, scalar: 1),
      'bool_invalid' => AbiErlangFixture.parameter(kind: 3, scalar: 2),
      'domain_valid' => AbiErlangFixture.parameter(kind: 6, index: 0),
      'domain_invalid' => AbiErlangFixture.parameter(kind: 6, index: 1),
      'name_valid' => AbiErlangFixture.parameter(kind: 4, text: 'valid'),
      'name_invalid' => AbiErlangFixture.parameter(kind: 4, text: 'bad/name'),
      'name_dotted' => AbiErlangFixture.parameter(kind: 4, text: 'a.b'),
      'path_valid' => AbiErlangFixture.parameter(kind: 5, text: '/public'),
      'path_invalid' => AbiErlangFixture.parameter(kind: 5, text: 'relative'),
      'opaque_bytes' => AbiErlangFixture.parameter(kind: 9, text: "\xff\0".b)
    }
    fixtures.each do |name, bytes|
      File.binwrite(File.join(@directory, name + '.bin'), bytes)
    end
  end

  def decode_json_values(value)
    case value
    when Hash
      if value.keys == ['bytes']
        [value.fetch('bytes')].pack('H*')
      else
        value.transform_values { |item| decode_json_values(item) }
      end
    when Array
      value.map { |item| decode_json_values(item) }
    else value
    end
  end
end
