# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/abi'

# Runs test/erlang/erx_usb_desc_tests.erl and erx_usb_claim_tests.erl, the cases of the
# USB descriptor decoder and of the claim with its endpoint parameters, against the
# modules compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Then each seeded fault of docs/design-usb.md, "Host tests of the
# cores", applied to a copy of its module, must fail the case named for it: the walk run
# over the bytes received instead of wTotalLength, so a trailing interface is claimed;
# the second definition of an interface setting kept over the first; the duplicate-
# address rule removed; the payload computed as packet size times burst, so a high-speed
# interrupt endpoint of 1024 bytes and one extra transaction is admitted to a 1 KiB
# buffer; the payload computed as the product at SuperSpeed, so the fixture's payload
# says 64; a hub function on every interface of a hub device, where FreeBSD gives one,
# on interface 0; and the high-speed interval's upper bound removed, so a bInterval of
# 17 gives an exponent past xHCI's 15.
#
# The modules take their bounds from abi/formats/ while the cases write each number out,
# so one more seeded fault edits a copy of xhci.txt instead, with erx_abi.hrl generated
# again from it: the interrupt buffer doubled must fail the high-speed payload case.
class ErxUsbDescTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_usb].freeze
  DESC = 'erlang/apps/erx_usb/src/erx_usb_desc.erl'
  CLAIM = 'erlang/apps/erx_usb/src/erx_usb_claim.erl'
  TESTS = %w[test/erlang/erx_hid_desc_tests.erl test/erlang/erx_usb_desc_tests.erl
             test/erlang/erx_usb_claim_tests.erl].freeze
  CASES = %w[erx_usb_desc_tests erx_usb_claim_tests].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :file, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the walk run over the bytes received instead of wTotalLength', file: DESC,
             anchor: 'Body:(Total - ?ERX_USB_CONFIGURATION_DESCRIPTOR_SIZE)/binary, _Unread/binary>> = Bytes,',
             replacement: 'Body/binary>> = Bytes,',
             catching_case: 'the_walk_stops_at_wtotallength_test'),
    Seed.new(fault: 'the second definition of an interface setting kept over the first', file: DESC,
             anchor: 'check(not is_map_key(Key, Settings), duplicate_interface),',
             replacement: 'check(is_tuple(Key), duplicate_interface),',
             catching_case: 'a_second_definition_of_an_interface_setting_is_refused_test'),
    Seed.new(fault: 'the duplicate-address rule removed', file: CLAIM,
             anchor: 'check(length(Addresses) =:= map_size(maps:from_keys(Addresses, [])), duplicate_endpoint),',
             replacement: 'check(is_list(Addresses), duplicate_endpoint),',
             catching_case: 'no_endpoint_belongs_to_two_functions_test'),
    Seed.new(fault: 'the payload computed as packet size times burst', file: CLAIM,
             anchor: 'Payload = payload(Type, Speed, PacketSize * (Burst + 1), Companion),',
             replacement: 'Payload = payload(Type, Speed, PacketSize * Burst, Companion),',
             catching_case: 'a_high_speed_interrupt_payload_counts_every_transaction_test'),
    Seed.new(fault: 'the payload computed as the product at SuperSpeed', file: CLAIM,
             anchor: "    Declared;\n",
             replacement: "    Product;\n",
             catching_case: 'a_superspeed_interrupt_payload_is_the_companions_bytes_per_interval_test'),
    Seed.new(fault: "a hub function on every interface of a hub device", file: CLAIM,
             anchor: 'driver(Speed, #{class := ?ERX_USB_CLASS_HUB, protocol := Protocol}, _Quirks, 0, _Setting) ->',
             replacement: 'driver(Speed, #{class := ?ERX_USB_CLASS_HUB, protocol := Protocol}, _Quirks, _Number, _Setting) ->',
             catching_case: 'a_hub_device_runs_one_hub_function_on_interface_0_test'),
    Seed.new(fault: "the high-speed interval's upper bound removed", file: CLAIM,
             anchor: 'check(Interval >= 1 andalso Interval =< ?ERX_XHCI_INTERVAL_BINTERVAL_MAX, malformed_descriptor),',
             replacement: 'check(Interval >= 1, malformed_descriptor),',
             catching_case: 'the_interval_exponent_follows_xhcis_table_test')
  ].freeze

  TABLE_SEED = Seed.new(fault: 'the interrupt buffer doubled', file: 'abi/formats/xhci.txt',
                        anchor: 'limit xhci_interrupt_buffer_size u32 1024',
                        replacement: 'limit xhci_interrupt_buffer_size u32 2048',
                        catching_case: 'a_high_speed_interrupt_payload_counts_every_transaction_test')

  def test_usb_desc_and_claim_cases_pass_under_eunit
    output, status = run_cases
    assert status.success?, output
    assert_equal CASES.size, output.scan(/All \d+ tests passed/).size, output
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ROOT, seed.file))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(replaced: { seed.file => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_case_failed(output, seed)
    end
  end

  def test_a_bound_changed_in_the_table_fails_its_case
    Dir.mktmpdir('erx-usb-desc-abi') do |root|
      # Only a module compiled here, not the build's own, reads the seeded header.
      output, status = run_cases(replaced: { CLAIM => File.binread(File.join(ROOT, CLAIM)) },
                                 includes: [seeded_header(root, TABLE_SEED)])
      refute status.success?, "#{TABLE_SEED.fault}: the cases passed"
      assert_case_failed(output, TABLE_SEED)
    end
  end

  private

  # eunit's verbose line for the seed's catching case reports it failed; another case's
  # failure further on does not count.
  def assert_case_failed(output, seed)
    assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
  end

  # Copies abi/ under root, applies the seed to its copy of the table and writes the
  # erx_abi.hrl generated from it to root/include/generated/, the path the modules'
  # -include("generated/erx_abi.hrl") names. Returns root/include, searched first.
  def seeded_header(root, seed)
    FileUtils.cp_r(File.join(ROOT, 'abi'), root)
    table = File.join(root, seed.file)
    text = File.binread(table)
    assert_equal 1, text.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
    File.binwrite(table, text.sub(seed.anchor) { seed.replacement })
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    File.join(root, 'include').tap do |directory|
      FileUtils.mkdir_p(File.join(directory, 'generated'))
      File.write(File.join(directory, 'generated', 'erx_abi.hrl'), Erx::ABI::ErlangEmitter.header(schema))
    end
  end

  # The modules' texts compiled in place of the application's own, then both case
  # modules; includes are searched for headers before the build's own.
  def run_cases(replaced: {}, includes: [])
    Dir.mktmpdir('erx-usb-desc-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced, includes: includes)
      tests = CASES.map { |name| "eunit:test(#{name}, [verbose])" }.join(', ')
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "halt(case lists:usort([#{tests}]) of [ok] -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
