# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ssh_dev_tests.erl, the cases of SSH's first stage
# (docs/design-ssh.md, "Stages"), against erx_ssh_dev compiled with the session
# application and erXos's ssh, every module of otp/lib/ssh/src ahead of stock's on the
# code path, on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies): root
# logs in with the login key or a key of its home copy and runs an expression, another
# user name and another key are refused, a home line with options and a home file past
# 16 KiB admit nothing, the daemon starts once the session's net and data facets are
# both installed, through the registry wait, the import writes the medium's keys only into a missing home
# copy and never an empty one, the host key is made once, owner-only and whole, and
# kept, and start/1 refuses stock's release, whose missing build facts name no
# development build. The module as the build compiles it exports no function that names
# a keys file. Each seeded fault must fail the cases: the wait for data dropped, a key callback that admits every
# user name, a home copy imported again or written empty, the medium's blobs written
# without being decoded, a medium file of any length
# taken as blobs, keys files read by OTP's ssh_file, the default version banner (OTP's
# id_string, Erlang/<version>, in place of erXos_<release>), exec run by OTP, a job's
# input sent in pieces past tty_line_data_max, a second piece or job_eof sent before
# the last piece is answered, an end of input before the exec dropped, an SSH event of
# another connection or channel taken, a job's relay not watched, OTP's channel opening the
# window after each data message, a job's ending heard without its alias, any build kind taken for
# a development one, and OTP's encoding of an Ed25519 private key without its public
# half, which ssh_file cannot read back as a host key.
class ErxSshDevTest < Minitest::Test
  SSH = File.join(ErlangBuild::ROOT, 'otp/lib/ssh/src')
  APPLICATIONS = %w[erx erx_shell erx_tty_line erx_session].freeze
  TESTS = %w[test/erlang/erx_ssh_dev_tests.erl].freeze
  DEV = 'erlang/apps/erx_session/src/erx_ssh_dev.erl'
  CHANNEL = 'erlang/apps/erx_session/src/erx_ssh_dev_channel.erl'
  CORE = 'erlang/apps/erx_tty_line/src/erx_ssh_job_core.erl'
  CLIENT_CHANNEL = 'otp/lib/ssh/src/ssh_client_channel.erl'
  Fault = Data.define(:name, :source, :from, :to)
  FAULTS = [
    Fault.new(name: 'the wait for data dropped', source: DEV,
              from: 'installed([net, data], Deadline)', to: 'installed([net], Deadline)'),
    Fault.new(name: 'a callback for every user name', source: DEV,
              from: 'is_auth_key(Key, ?USER, Options) ->', to: 'is_auth_key(Key, _, Options) ->'),
    Fault.new(name: 'the home copy imported again', source: DEV,
              from: '{ok, _} -> kept;', to: '{ok, _} -> import_keys(Home, Medium());'),
    Fault.new(name: 'an empty home copy written', source: DEV,
              from: '{_Text, 0} ->', to: '{_Text, -1} ->'),
    Fault.new(name: "the medium's blobs written without being decoded", source: DEV,
              from: '{ok, Keys, _Findings} = erx_boot_keys:decode(iolist_to_binary(Lines)),',
              to: 'Keys = [Blob || [_, Encoded, _] <- Lines, Blob <- [base64:decode(Encoded)]],'),
    Fault.new(name: 'a medium file of any length read as blobs', source: DEV,
              from: 'byte_size(Bytes) rem Size =:= 0 andalso', to: 'true andalso'),
    Fault.new(name: 'a keys file read by ssh_file', source: DEV,
              from: '{ok, Blobs, _Findings} ?= erx_boot_keys:decode(Bytes),',
              to: 'Blobs = [ssh_file:encode(K, ssh2_pubkey) || {K, _} <- ssh_file:decode(Bytes, auth_keys)],'),
    Fault.new(name: 'the default version banner', source: DEV,
              from: '{id_string, ?ID_STRING},', to: ''),
    Fault.new(name: 'exec run by OTP', source: DEV,
              from: '{ssh_cli, {erx_ssh_dev_channel, [Open, Job]}},', to: '{exec, erlang_eval},'),
    Fault.new(name: "a job's input in pieces past tty_line_data_max", source: CORE,
              from: 'lists:foldl(fun queue:in/2, Pieces, pieces(Bytes))', to: 'queue:in(Bytes, Pieces)'),
    Fault.new(name: 'a second piece before job_written', source: CORE,
              from: 'feed(#{job := started, unanswered := none, pieces := Pieces, eof := Eof} = Channel, Actions) ->',
              to: 'feed(#{job := started, pieces := Pieces, eof := Eof} = Channel, Actions) ->'),
    Fault.new(name: 'job_eof before job_written', source: CORE,
              from: 'feed(Channel#{eof := pending}, []);', to: '{Channel#{eof := sent}, [{send, job_eof}]};'),
    Fault.new(name: 'an end of input before the exec dropped', source: CORE,
              from: 'channel_step(eof, #{eof := none} = Channel) ->',
              to: 'channel_step(eof, #{eof := none, job := started} = Channel) ->'),
    Fault.new(name: 'an SSH event of another connection or channel taken', source: CHANNEL,
              from: "{ssh_cm, Connection, Event}, #state{connection = Connection, channel = Channel} = State)\n  " \
                    'when is_tuple(Event), tuple_size(Event) >= 2, element(2, Event) =:= Channel ->',
              to: "{ssh_cm, _Connection, Event}, State)\n  when is_tuple(Event), tuple_size(Event) >= 2 ->"),
    Fault.new(name: "a job's relay not watched", source: CHANNEL,
              from: 'watched = monitor(process, Relay)', to: 'watched = make_ref()'),
    Fault.new(name: 'the window opened after each data message', source: CLIENT_CHANNEL,
              from: "AutoAdjust andalso adjust_window(Msg),\n\t    {noreply, State#state{channel_state = ChannelState}};",
              to: "adjust_window(Msg),\n\t    {noreply, State#state{channel_state = ChannelState}};"),
    Fault.new(name: "a job's ending heard without its alias", source: CHANNEL,
              from: "    job({heard, Message}, State);\n",
              to: "    job({heard, Message}, State);\nhandle_msg({exited, _} = Message, State) ->\n    job({heard, Message}, State);\n"),
    Fault.new(name: 'any build kind taken for a development one', source: 'erlang/apps/erx/src/erx_build.erl',
              from: '[_Platform, Kind] -> kind(Kind) =:= {ok, development};', to: '[_Platform, _Kind] -> true;'),
    Fault.new(name: 'an Ed25519 private key without its public half', source: 'otp/lib/ssh/src/ssh_message.erl',
              from: '?STRING(<<Priv/binary, Pub/binary>>)>>;', to: '?STRING(Priv)>>;')
  ].freeze

  def test_the_daemon_admits_root_with_the_login_key_alone
    in_build do |work|
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # The module as the build compiles it offers boot/1, start/1 and the key callback
  # alone, so no entry of a shipped image names a keys file or a host-key directory.
  def test_the_shipped_module_names_no_keys_file
    Dir.mktmpdir('erx-ssh-dev-shipped') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS)
      output, status = erl(work, 'io:format("~w~n", [lists:sort(erx_ssh_dev:module_info(exports))]), halt().')
      assert status.success?, output
      assert_equal '[{boot,1},{host_key,2},{is_auth_key,3},{module_info,0},{module_info,1},{start,1}]', output.strip
    end
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = File.read(File.join(ErlangBuild::ROOT, fault.source))
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{fault.source}"
      faulty = text.sub(fault.from, fault.to)
      in_build(fault.source.start_with?('otp/') ? { ssh: { fault.source => faulty } } : { session: { fault.source => faulty } }) do |work|
        output, status = eunit(work)
        refute status.success?, "#{fault.name} passed erx_ssh_dev_tests:\n#{output}"
      end
    end
  end

  private

  # A work directory with the session's modules and the tests, and erXos's ssh in its
  # own ssh directory; replaced.fetch(:ssh) maps an ssh module's path to the text
  # compiled in place of the tree's.
  # erx_ssh_dev is compiled again over the build's, with TEST defined, which exports
  # daemon/2 to the cases; replaced.fetch(:session) is its text in place of the tree's.
  def in_build(replaced = {})
    Dir.mktmpdir('erx-ssh-dev-test') do |work|
      ebin = File.join(work, 'ssh')
      Dir.mkdir(ebin)
      sources = Dir[File.join(SSH, '*.erl')].sort
      replaced.fetch(:ssh, {}).each do |path, text|
        name = File.basename(path)
        File.write(File.join(work, name), text)
        sources = sources.map { |source| File.basename(source) == name ? File.join(work, name) : source }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', ebin, '-I', SSH, *sources, stdin_data: '')
      assert status.success?, output
      session = { DEV => File.read(File.join(ErlangBuild::ROOT, DEV)) }.merge(replaced.fetch(:session, {}))
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: session, defines: %w[TEST])
      yield work
    end
  end

  # erl's -pa puts the last directory it is given first on the code path. The cases'
  # keys, host keys and clients live in a directory of work's, ERX_SSH_DEV_WORK.
  def eunit(work)
    cases = File.join(work, 'cases')
    Dir.mkdir(cases)
    erl(work, 'halt(case eunit:test(erx_ssh_dev_tests, [verbose]) of ok -> 0; _ -> 1 end).',
        env: { 'ERX_SSH_DEV_WORK' => cases })
  end

  def erl(work, expression, env: {})
    Open3.capture2e(env, 'gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    File.join(work, 'ssh'), '-eval', expression, chdir: work, stdin_data: '')
  end
end
