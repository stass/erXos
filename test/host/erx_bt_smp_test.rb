# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_smp_tests.erl, the cases of the Security Manager's cores:
# erx_smp_crypto against Core 6.3 Vol 3 Part H, Appendix D, erx_smp's layouts and
# erx_smp_core, its refusals and its exploration, compiled from source on stock's
# emulator (ERX_ERL and ERX_ERLC). Then each seeded fault of docs/design-bluetooth.md,
# "Host tests of the cores", and of the checks against a hostile phone, applied to a
# copy of its module, must fail the case named for it.
class ErxBtSmpTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_smp_tests.erl].freeze
  DEADLINE_SECONDS = '300'
  CORE = 'erlang/apps/erx_bt/src/erx_smp_core.erl'
  CRYPTO = 'erlang/apps/erx_bt/src/erx_smp_crypto.erl'
  EXPLORED = 'explored_core_keeps_its_invariants_test_'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the key-size check removed',
             module_path: CORE,
             anchor: 'require(MaxKey >= ?ERX_SMP_KEY_SIZE_ERXOS, ?ERX_SMP_REASON_ENCRYPTION_KEY_SIZE, key_size),',
             replacement: '',
             catching_case: 'key_size_test'),
    Seed.new(fault: 'the curve check removed, so the y + 1 point is accepted',
             module_path: CORE,
             anchor: 'require(erx_smp_crypto:on_curve(Key), ?ERX_SMP_REASON_DHKEY_CHECK_FAILED, dhkey),',
             replacement: '',
             catching_case: 'off_curve_key_fails_dhkey_test'),
    Seed.new(fault: 'the link-key bit kept',
             module_path: CORE,
             anchor: 'initiator_keys => erx_smp:keys_octet(#{enc => false, id => true, link => false}),',
             replacement: 'initiator_keys => erx_smp:keys_octet(#{enc => false, id => true, link => true}),',
             catching_case: 'response_test'),
    Seed.new(fault: 'the reflected key accepted',
             module_path: CORE,
             anchor: 'require(X =/= OwnX, ?ERX_SMP_REASON_DHKEY_CHECK_FAILED, dhkey),',
             replacement: '',
             catching_case: 'reflected_key_fails_dhkey_test'),
    Seed.new(fault: 'the debug key accepted',
             module_path: CORE,
             anchor: 'require(Key =/= erx_smp_crypto:debug_key(), ?ERX_SMP_REASON_INVALID_PARAMETERS, invalid),',
             replacement: '',
             catching_case: 'debug_key_fails_invalid_parameters_test'),
    Seed.new(fault: "a Passkey Entry round's commitment not checked",
             module_path: CORE,
             anchor: 'require(crypto:hash_equals(Confirm, ',
             replacement: 'require(true orelse crypto:hash_equals(Confirm, ',
             catching_case: EXPLORED),
    Seed.new(fault: "the phone's DHKey check value not checked",
             module_path: CORE,
             anchor: 'require(crypto:hash_equals(Ea, Expected),',
             replacement: 'require(true orelse crypto:hash_equals(Ea, Expected),',
             catching_case: EXPLORED),
    Seed.new(fault: 'a display window taking Just Works',
             module_path: CORE,
             anchor: 'display -> fail(?ERX_SMP_REASON_AUTHENTICATION_REQUIREMENTS, method)',
             replacement: 'display -> just_works',
             catching_case: 'method_test'),
    Seed.new(fault: "the passkey's bits taken most significant first",
             module_path: CORE,
             anchor: '16#80 bor ((Passkey bsr Round) band 1)',
             replacement: '16#80 bor ((Passkey bsr (19 - Round)) band 1)',
             catching_case: 'passkey_entry_completes_authenticated_test'),
    Seed.new(fault: "a private address taken as the phone's static random identity",
             module_path: CRYPTO,
             anchor: 'static_random(<<2#11:2, Random:46>>)',
             replacement: 'static_random(<<_:1, 1:1, Random:46>>)',
             catching_case: 'identity_address_test'),
    Seed.new(fault: 'the AES-CMAC key byte order reversed',
             module_path: CRYPTO,
             anchor: 'aes_cmac(Key, Message) -> crypto:mac(cmac, aes_128_cbc, Key, Message).',
             replacement: 'aes_cmac(Key, Message) -> crypto:mac(cmac, aes_128_cbc, ' \
                          'list_to_binary(lists:reverse(binary_to_list(Key))), Message).',
             catching_case: 'aes_cmac_matches_appendix_d1_test'),
    Seed.new(fault: 'a verdict applied whatever request it answers',
             module_path: CORE,
             anchor: 'phase({admission, Tag, Verdict}, {admitting, Request}, #{tag := Tag})',
             replacement: 'phase({admission, _Tag, Verdict}, {admitting, Request}, _)',
             catching_case: 'stale_verdict_ignored_test'),
    Seed.new(fault: 'a failure after the key leaves the link up and pairing again',
             module_path: CORE,
             anchor: 'true -> {Reported ++ [end_link], State#{phase := ended}};',
             replacement: 'true -> {Reported, State#{phase := idle}};',
             catching_case: 'failure_after_key_ends_link_test')
  ].freeze

  def test_security_manager_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  # A reason outside abi/formats/bluetooth.txt's bt_pair_reason, written where the
  # Security Manager fails a pairing, fails at failed/1, which makes every failure it
  # reports, and reaches no
  # window or line.
  def test_a_stray_reason_fails_at_its_producer
    anchor = 'fail(?ERX_SMP_REASON_UNSPECIFIED_REASON, unexpected)'
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    assert_equal 1, source.scan(anchor).size, 'stray reason anchor is not unique'
    output, status = run_cases({ CORE => source.sub(anchor) { anchor.sub('unexpected', 'unexpectd') } })
    refute status.success?, 'a stray reason passed'
    assert_match(/identity_before_encryption_fails_test[^\n]*\*failed\*\nin function erx_smp_core:failed\/1(?:(?!erx_bt_smp_tests: ).)*?\*\*error:function_clause/m,
                 output)
  end

  private

  # The modules, with replaced ones in place of the application's own, then the cases.
  def run_cases(replaced)
    Dir.mktmpdir('erx-bt-smp-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_bt_smp_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
