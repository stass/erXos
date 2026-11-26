# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/gatt_decl'

# tools/lib/erx/gatt_decl.rb, the GATT service declarations' generator
# (docs/design-bluetooth.md, "Declarations: `abi/gatt`"): abi/gatt/nus.txt parses to the
# service the design's example declares; each refusal the section names fires on an input
# that breaks only it, beside a passing neighbour where the bound is a number; and the
# generated erx_gatt_decl, compiled and run on stock's emulator (ERX_ERL and ERX_ERLC),
# gives a declaration's 16-bit UUID, initial value and empty characteristic list as
# erx_gatt_db:build/2 takes them. test/erlang/erx_bt_gatt_tests.erl builds the table from
# the generated module the build compiles.
class GattDeclTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEADLINE_SECONDS = '120'
  PATH = 'abi/gatt/svc.txt'
  VOCABULARY = Erx::GattDecl.vocabulary(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
  SERVICE = 'service svc 0000aaaa-0000-4000-8000-00000000beef'
  CHAR = 'characteristic c 0000aaab-0000-4000-8000-00000000beef'

  def parse(*lines, path: PATH, service: SERVICE)
    text = [service, *lines].compact.join("\n") + "\n"
    Erx::GattDecl.parse(path: path, text: text, vocabulary: VOCABULARY)
  end

  def assert_refused(pattern, *lines, **options)
    error = assert_raises(Erx::GattDecl::DeclarationError) { parse(*lines, **options) }
    assert_match pattern, error.message
  end

  def test_the_nus_declaration_is_the_designs_example
    path = 'abi/gatt/nus.txt'
    nus = Erx::GattDecl.parse(path: path, text: File.read(File.join(ROOT, path)), vocabulary: VOCABULARY)
    uuid = ->(digit) { Erx::GattDecl::Uuid.new(bits: 128, value: "6e40000#{digit}b5a3f393e0a9e50e24dcca9e".to_i(16)) }
    assert_equal ['nus', uuid.call(1), true], [nus.name, nus.uuid, nus.advertise]
    assert_equal [['rx', uuid.call(2), 244, { 'write' => 'open', 'write_without_response' => 'open' }, nil],
                  ['tx', uuid.call(3), 244, { 'notify' => 'open' }, nil]],
                 nus.characteristics.map { |c| [c.name, c.uuid, c.max, c.access, c.value] }
  end

  # The bond check's service (docs/design-bluetooth.md, "On QEMU against Bumble", "The bond
  # check"): three constants, each its own level's name in ASCII, read at the three levels
  # above open, with no write, no subscription and no advertising.
  def test_the_bondcheck_declaration_is_the_designs
    path = 'abi/gatt/bondcheck.txt'
    bondcheck = Erx::GattDecl.parse(path: path, text: File.read(File.join(ROOT, path)), vocabulary: VOCABULARY)
    uuid = ->(digit) { Erx::GattDecl::Uuid.new(bits: 128, value: "eb417d#{digit}58b14f45b9f5e9e24e229b0f".to_i(16)) }
    assert_equal ['bondcheck', uuid.call('8e'), false], [bondcheck.name, bondcheck.uuid, bondcheck.advertise]
    assert_equal [['encrypted', uuid.call('8f'), 9, { 'read' => 'encrypted' }, 'encrypted'],
                  ['authenticated', uuid.call('90'), 13, { 'read' => 'authenticated' }, 'authenticated'],
                  ['bonded', uuid.call('91'), 6, { 'read' => 'bonded' }, 'bonded']],
                 bondcheck.characteristics.map { |c| [c.name, c.uuid, c.max, c.access, c.value] }
  end

  def test_a_missing_or_repeated_service_line_is_refused
    assert_refused(/no service line/, service: '# nothing declared')
    assert_refused(/svc.txt:1: a characteristic before the service line/, service: "#{CHAR} 244 read open")
    assert_refused(/svc.txt:2: a second service line/, SERVICE)
  end

  def test_the_service_names_its_file
    assert_refused(/service svc in a file named other/, path: 'abi/gatt/other.txt')
    assert_refused(/"Svc" is not a service name/, path: 'abi/gatt/Svc.txt')
  end

  def test_a_malformed_uuid_is_refused
    assert_refused(/0000AAAA-0000-4000-8000-00000000BEEF is not a 16-bit or 128-bit UUID/,
                   service: 'service svc 0000AAAA-0000-4000-8000-00000000BEEF')
    assert_refused(/0000aaaa0000400080000000000beef is not/, service: 'service svc 0000aaaa0000400080000000000beef')
    assert_refused(/2a3 is not/, 'characteristic c 2a3 20 read open')
    assert_equal 0x2a37, parse('characteristic c 2a37 20 read open').characteristics.first.uuid.value
  end

  # A UUID of the Base UUID with a 16-bit value has one spelling, its 16 bits, so a phone's
  # Find By Type Value of the 2-octet form finds it; a 32-bit one keeps its 128-bit form.
  def test_the_long_form_of_a_16_bit_uuid_is_refused
    assert_refused(/00002a37-0000-1000-8000-00805f9b34fb is written 2a37, in 16 bits/,
                   'characteristic c 00002a37-0000-1000-8000-00805f9b34fb 20 read open')
    assert_refused(/00002902-0000-1000-8000-00805f9b34fb is written 2902, in 16 bits/,
                   'characteristic c 00002902-0000-1000-8000-00805f9b34fb 20 read open')
    long = parse('characteristic c 00012a37-0000-1000-8000-00805f9b34fb 20 read open').characteristics.first.uuid
    assert_equal 128, long.bits
  end

  def test_gatt_and_gaps_own_uuids_are_refused
    assert_refused(/2803 is GATT's or GAP's own UUID characteristic/, 'characteristic c 2803 20 read open')
    assert_refused(/1800 is GATT's or GAP's own UUID gap_service/, service: 'service svc 1800')
    assert_equal 9, VOCABULARY.reserved.size
  end

  # A UUID of GATT's attribute types beyond the enum's, an Include declaration or a
  # descriptor, is refused for a characteristic as for a service. Below the blocks 0x27ff
  # passes; above them 0x2a00 and 0x2a01 are the enum's Device Name and Appearance, so
  # 0x2a02 is the first that passes.
  def test_gatt_attribute_types_are_refused
    %w[2802 2804 28ff 2900 2901 29ff].each do |uuid|
      assert_refused(/#{uuid} is a GATT attribute type/, "characteristic c #{uuid} 20 read open")
    end
    assert_refused(/2900 is a GATT attribute type/, service: 'service svc 2900')
    %w[27ff 2a02].each { |uuid| assert parse("characteristic c #{uuid} 20 read open") }
  end

  def test_the_tables_own_service_names_are_refused
    %w[gap gatt].each do |name|
      assert_refused(/#{name} is the name of the table's own service/,
                     path: "abi/gatt/#{name}.txt", service: "service #{name} 0000aaaa-0000-4000-8000-00000000beef")
    end
  end

  def test_two_characteristics_of_one_name_or_uuid_are_refused
    assert_refused(/:3: a second characteristic c/, "#{CHAR} 20 read open", 'characteristic c 2a37 20 read open')
    assert_refused(/:3: d has c's UUID/, "#{CHAR} 20 read open", 'characteristic d 0000aaab-0000-4000-8000-00000000beef 20 read open')
    assert_refused(/:3: d has c's UUID/, 'characteristic c 2a37 20 read open', 'characteristic d 2a37 20 read open')
  end

  def test_a_maximum_over_512_is_refused
    assert_refused(/a maximum of 513, over 512/, "#{CHAR} 513 read open")
    assert_equal 512, parse("#{CHAR} 512 read open").characteristics.first.max
    assert_refused(/0x20 is not a length in decimal/, "#{CHAR} 0x20 read open")
  end

  def test_an_access_without_a_level_or_repeated_is_refused
    assert_refused(/read has no level/, "#{CHAR} 20 read")
    assert_refused(/read has no level/, "#{CHAR} 20 read write open")
    assert_refused(/read has no level/, "#{CHAR} 20 read value 00")
    assert_refused(/read given twice/, "#{CHAR} 20 read open read open")
    assert_refused(/public is not a level/, "#{CHAR} 20 read public")
    assert_refused(/subscribe is not an access/, "#{CHAR} 20 subscribe open")
  end

  def test_notify_and_indicate_at_different_levels_are_refused
    assert_refused(/c notifies open and indicates encrypted/, "#{CHAR} 20 notify open indicate encrypted")
    access = parse("#{CHAR} 20 indicate encrypted notify encrypted").characteristics.first.access
    assert_equal({ 'notify' => 'encrypted', 'indicate' => 'encrypted' }, access)
  end

  def test_a_characteristic_with_no_access_is_refused
    assert_refused(/c allows no access/, "#{CHAR} 20")
    assert_refused(/c allows no access/, "#{CHAR} 20 value 00")
  end

  def test_an_initial_value_past_its_maximum_or_not_readable_is_refused
    assert_refused(/an initial value of 3 octets, over c's maximum/, "#{CHAR} 2 read open value 010203")
    assert_equal "\x01\x02".b, parse("#{CHAR} 2 read open value 0102").characteristics.first.value
    assert_refused(/an initial value of c, which is not readable/, "#{CHAR} 2 write open value 01")
    assert_refused(/value takes one string/, "#{CHAR} 2 read open value 0G")
    assert_refused(/value takes one string/, "#{CHAR} 2 read open value 01 02")
  end

  def test_a_byte_above_0x7f_or_a_control_byte_is_refused
    assert_refused(/svc.txt:2: a byte above 0x7f, 0xc3/, "#{CHAR} 20 read open # caf\u00e9")
    assert_refused(/svc.txt:2: a control byte, 0x09/, "#{CHAR}\t20 read open")
  end

  def test_other_malformed_lines_are_refused
    assert_refused(/descriptor is not a line of a GATT declaration/, 'descriptor d 2901')
    assert_refused(/a service line is service NAME UUID \[advertise\]/, service: "#{SERVICE} advertised")
    assert_refused(/a characteristic line is characteristic NAME UUID MAX/, 'characteristic c 2a37')
    assert_refused(/C is not a name/, 'characteristic C 2a37 20 read open')
  end

  def test_a_tree_without_a_declaration_is_refused
    with_abi_copy do |root|
      FileUtils.rm_r(File.join(root, 'abi/gatt'))
      error = assert_raises(Erx::GattDecl::DeclarationError) { Erx::GattDecl.generation(root: root) }
      assert_match %r{no GATT service declaration matches abi/gatt/\*\.txt}, error.message
    end
  end

  # A reserved word names a service like any other, a 16-bit UUID and an initial value
  # reach the term least significant octet first and as given, a service of no
  # characteristics has an empty list, and names/0 and advertised/0 follow the files.
  def test_the_generated_module_gives_the_terms_build_takes
    with_abi_copy do |root|
      File.write(File.join(root, 'abi/gatt/end.txt'),
                 "service end 180f\ncharacteristic level 2a19 20 read open notify encrypted value 6400000000000000000000000102\n")
      File.write(File.join(root, 'abi/gatt/empty.txt'), "service empty 0000aaaa-0000-4000-8000-00000000beef\n")
      assert_equal %w[true true true true], module_output(root: root, eval: TERMS)
    end
  end

  # Each of the generated module's answers against the term written out here, octet by
  # octet; a mismatch prints the module's answer.
  TERMS = <<~'ERLANG'
    Check = fun(Expected, Actual) -> io:format("~w~n", [Expected =:= Actual orelse Actual]) end,
    Check([bondcheck, 'empty', 'end', nus], erx_gatt_decl:names()),
    Check([nus], erx_gatt_decl:advertised()),
    Check(#{name => 'end', uuid => <<16#0F, 16#18>>,
            characteristics => [#{name => level, uuid => <<16#19, 16#2A>>, max => 20,
                                  access => #{read => open, notify => encrypted},
                                  value => <<100, 0:88, 1, 2>>}]},
          erx_gatt_decl:service('end')),
    Check(#{name => empty, uuid => <<16#EF, 16#BE, 0:40, 16#80, 0, 16#40, 0, 0, 16#AA, 16#AA, 0, 0>>,
            characteristics => []},
          erx_gatt_decl:service(empty)),
    halt(0).
  ERLANG

  def with_abi_copy
    Dir.mktmpdir('erx-gatt-root') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      yield root
    end
  end

  # The module the generator plans for root, compiled, and the lines the Erlang
  # expression eval prints with it loaded.
  def module_output(root:, eval:)
    Dir.mktmpdir('erx-gatt-test') do |work|
      File.write(File.join(work, 'erx_gatt_decl.erl'),
                 Erx::GattDecl.generation(root: root).files.fetch(Erx::GattDecl::OUTPUT))
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-Werror',
                                       '-o', work, 'erx_gatt_decl.erl', chdir: work, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval', eval, chdir: work, stdin_data: '')
      assert status.success?, output
      output.lines.map(&:chomp)
    end
  end
end
