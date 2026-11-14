# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_ssh_edits_tests.erl, the host tests of erXos's edits to
# OTP's ssh (docs/design-ssh.md, "Edits to OTP's ssh" and "Verification"), on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies): every
# module of otp/lib/ssh/src is compiled into a directory of its own, ahead of
# stock's ssh on the code path, and a second copy of ssh_transport whose client
# offers no strict key exchange serves the cases' peer client. Then each seeded
# fault the design names is compiled in place of its module, and the cases
# must fail on it, which shows they exercise what they guard.
class ErxSshEditsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SSH = File.join(ROOT, 'otp/lib/ssh/src')
  TESTS = %w[erx_ssh_edits_tests erx_ssh_edits_keys erx_ssh_edits_plain_keys
             erx_ssh_edits_client_keys].map { |name| File.join(ROOT, "test/erlang/#{name}.erl") }.freeze
  NO_STRICT = Data.define(:from, :to).new(from: 'kex_strict_alg(client) -> [?kex_strict_c, ?kex_strict_c_pre];',
                                          to: 'kex_strict_alg(client) -> [];')

  # Each fault: the module it is compiled into, the text replaced and its replacement.
  Fault = Data.define(:name, :module_name, :from, :to)
  FAULTS = [
    Fault.new(name: 'the input kept on the ECDH path alone', module_name: 'ssh_transport',
              from: "session_id = sid(Ssh1, H),\n                                      kex_input = first_input(Ssh1, PlainText)",
              to: "session_id = sid(Ssh1, H),\n                                      kex_input = undefined"),
    Fault.new(name: 'verify_user/6 handed the bare signature', module_name: 'ssh_auth',
              from: 'key_cb_verify_user(User, Alg, KeyBlob, AlgSig, Ssh)', to: 'key_cb_verify_user(User, Alg, KeyBlob, Sig, Ssh)'),
    Fault.new(name: 'a rekeying that stores its own input', module_name: 'ssh_transport',
              from: 'first_input(#ssh{kex_input = Input}, _PlainText) -> Input.',
              to: 'first_input(#ssh{}, PlainText) -> PlainText.'),
    Fault.new(name: 'the clear in connected_state/5 removed', module_name: 'ssh_fsm_userauth_server',
              from: 'ssh_params = Ssh#ssh{authenticated = true, kex_input = undefined}}.',
              to: 'ssh_params = Ssh#ssh{authenticated = true}}.'),
    Fault.new(name: 'format_status0(normal, ...) left stock', module_name: 'ssh_connection_handler',
              from: '[{data, [{"State", D#data{ssh_params = redact_kex_input(Ssh)}}]}];',
              to: '[{data, [{"State", D#data{ssh_params = Ssh}}]}];'),
    Fault.new(name: 'max_auth_tries not passed', module_name: 'ssh_auth',
              from: 'past_max_auth_tries(Failures, ?GET_OPT(max_auth_tries, Opts))', to: 'false'),
    Fault.new(name: 'verify_user/6 called for every module', module_name: 'ssh_auth',
              from: 'ssh_transport:key_cb_exports(verify_user, 6, Opts)', to: 'true')
  ].freeze

  def test_edits_under_eunit
    in_build do |work|
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    in_build do |work|
      FAULTS.each do |fault|
        source = File.join(SSH, "#{fault.module_name}.erl")
        text = File.read(source)
        assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{source}"
        faulty = File.join(work, 'fault')
        FileUtils.mkdir_p(faulty)
        compile(faulty, write(work, fault.module_name, text.sub(fault.from, fault.to)))
        output, status = eunit(work, first: faulty)
        refute status.success?, "#{fault.name} passed erx_ssh_edits_tests:\n#{output}"
        assert_match(/Failed: [1-9]|\*failed\*/, output, fault.name)
        FileUtils.rm_rf(faulty)
      end
    end
  end

  private

  def in_build
    Dir.mktmpdir('erx-ssh-edits-test') do |work|
      ebin = File.join(work, 'ssh')
      no_strict = File.join(work, 'nostrict')
      [ebin, no_strict].each { |dir| Dir.mkdir(dir) }
      compile(ebin, *Dir[File.join(SSH, '*.erl')].sort)
      transport = File.read(File.join(SSH, 'ssh_transport.erl'))
      assert_equal 1, transport.scan(NO_STRICT.from).size
      compile(no_strict, write(work, 'ssh_transport', transport.sub(NO_STRICT.from, NO_STRICT.to)))
      compile(work, *TESTS, pa: ebin)
      yield work
    end
  end

  def write(work, module_name, text)
    dir = File.join(work, 'src')
    FileUtils.mkdir_p(dir)
    File.join(dir, "#{module_name}.erl").tap { |path| File.write(path, text) }
  end

  def compile(directory, *sources, pa: nil)
    flags = ['-o', directory, '-I', SSH, *(pa ? ['-pa', pa] : [])]
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, *sources, stdin_data: '')
    assert status.success?, output
  end

  def eunit(work, first: nil)
    ebin = File.join(work, 'ssh')
    # erl's -pa puts the last directory it is given first on the code path.
    path = [first, ebin, work].compact.reverse
    Open3.capture2e({ 'ERX_SSH_EBIN' => ebin, 'ERX_SSH_NOSTRICT_EBIN' => File.join(work, 'nostrict') },
                    'gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'), '-noshell', '-pa', *path,
                    '-eval', 'halt(case eunit:test(erx_ssh_edits_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                    chdir: work, stdin_data: '')
  end
end
