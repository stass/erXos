# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/usb_quirks'

# tools/lib/erx/usb_quirks.rb, the USB mass-storage quirk table's generator
# (docs/design-usb.md, "Device quirks"): each refusal it names, then the generated
# erx_usb_quirks, compiled and run on stock's emulator (ERX_ERL and ERX_ERLC), against
# devices written here from the sources themselves, independently of the table: FreeBSD's
# MYSON HEDEN (04cf:8818, usb_quirk.c:328, usbdevs:180 and :3486) and its vendor-only MPMAN
# row (1cae, :322, usbdevs:747), and the Linux facts record's two rows of 04ce:0002, whose
# ranges differ by one kind. Two seeded faults, a lookup that ignores the range and a
# generator that drops a row's last kind, must each fail the lookup case.
class UsbQuirksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEADLINE_SECONDS = '120'
  KINDS = Erx::UsbQuirks.kinds(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
  HEAD = "source freebsd release/15.1.0 96841ea08dcf line\nsource linux v6.19.14 ca1def992480 bare\n"
  ROW = 'quirk 04cf:8818 0000-ffff ignore_residue no_sync_cache from freebsd:328'

  # Device, release and the kinds it takes, each from the sources the header names.
  CASES = [
    ['16#04cf, 16#8818, 16#0000', '[ignore_residue, no_sync_cache]'],
    ['16#04cf, 16#8818, 16#ffff', '[ignore_residue, no_sync_cache]'],
    ['16#1cae, 16#0001, 16#0100', '[no_sync_cache]'],
    ['16#04ce, 16#0002, 16#0100', '[capacity_is_count, ignore_csw_tag]'],
    ['16#04ce, 16#0002, 16#026c', '[capacity_is_count]'],
    ['16#04ce, 16#0002, 16#026d', '[]'],
    ['16#1234, 16#5678, 16#0100', '[]']
  ].freeze

  def parse(*rows, head: HEAD)
    Erx::UsbQuirks.parse(text: head + rows.join("\n") + "\n", kinds: KINDS)
  end

  def assert_refused(pattern, *rows, **options)
    error = assert_raises(Erx::UsbQuirks::TableError) { parse(*rows, **options) }
    assert_match pattern, error.message
  end

  def test_a_row_of_closed_set_names_parses
    rows = parse(ROW, 'quirk 04cf:8818 0100-0100 capacity_is_count from linux freebsd:328',
                 'quirk 1cae:* 0000-ffff no_sync_cache from freebsd:322')
    assert_equal [[0x04cf, 0x8818, 0, 0xffff], [0x04cf, 0x8818, 0x100, 0x100], [0x1cae, nil, 0, 0xffff]],
                 rows.map { |row| [row.vendor, row.product, row.low, row.high] }
  end

  def test_each_refusal
    {
      /no_start_stop is not a member of the enum usb_quirk/ => 'quirk 04cf:8818 0000-ffff no_start_stop from linux',
      /openbsd is not a declared source/ => 'quirk 04cf:8818 0000-ffff ignore_residue from openbsd',
      /"04CF:8818" is not VVVV:PPPP/ => 'quirk 04CF:8818 0000-ffff ignore_residue from linux',
      /"4cf:8818" is not VVVV:PPPP/ => 'quirk 4cf:8818 0000-ffff ignore_residue from linux',
      /"0000-fffff" is not LLLL-HHHH/ => 'quirk 04cf:8818 0000-fffff ignore_residue from linux',
      /the range 0200-0100 ends before it starts/ => 'quirk 04cf:8818 0200-0100 ignore_residue from linux',
      /ignore_residue is named twice/ => 'quirk 04cf:8818 0000-ffff ignore_residue ignore_residue from linux',
      /names no kind/ => 'quirk 04cf:8818 0000-ffff from linux',
      /cites no source/ => 'quirk 04cf:8818 0000-ffff ignore_residue from',
      /names its citations after from/ => 'quirk 04cf:8818 0000-ffff ignore_residue linux',
      /"freebsd:0" is not NAME or NAME:LINE/ => 'quirk 04cf:8818 0000-ffff ignore_residue from freebsd:0',
      /freebsd names no line of freebsd/ => 'quirk 04cf:8818 0000-ffff ignore_residue from freebsd',
      /linux:12 names a line of linux, cited bare/ => 'quirk 04cf:8818 0000-ffff ignore_residue from linux:12',
      /rows is not a line of the table/ => 'rows 04cf:8818'
    }.each { |pattern, row| assert_refused(pattern, row) }
  end

  def test_order_duplicates_sources_and_bytes_are_refused
    assert_refused(/04cf:8818 0000-ffff has a row already/, ROW, ROW)
    assert_refused(/1cae:\* 0000-ffff is out of order/, ROW, 'quirk 1cae:0001 0000-ffff no_sync_cache from linux',
                   'quirk 1cae:* 0000-ffff no_sync_cache from linux')
    assert_refused(/a source after the first quirk row/, ROW, 'source netbsd 10.2 0123456789ab bare')
    assert_refused(/source linux is declared already/, ROW, head: HEAD + "source linux v6 0123456789ab bare\n")
    assert_refused(/source takes a name, a release, a commit and a form/, ROW, head: "source freebsd 15.1 0123456789ab\n")
    assert_refused(/"v6.19" is not a commit/, ROW, head: "source freebsd 15.1 v6.19 line\n")
    assert_refused(/"0123456789AB" is not a commit/, ROW, head: "source freebsd 15.1 0123456789AB line\n")
    assert_refused(/"lines" is not one of line, bare/, ROW, head: "source freebsd 15.1 0123456789ab lines\n")
    assert_refused(/a byte above 0x7f, 0xc3/, "#{ROW} # caf\xC3\xA9")
    assert_refused(/no quirk row/)
  end

  # The leading comment, which the image's NOTICES carries, holds erXos's copyright line and
  # usb_quirk.c's notice that the table reproduces, its copyright lines and disclaimer.
  def test_the_generated_module_carries_the_notice
    header = generated.lines.take_while { |line| line.start_with?("%%") }.join
    ["Copyright (c) 2026, Stanislav Sedov", "Copyright (c) 1998 The NetBSD Foundation, Inc.",
     "Copyright (c) 1998 Lennart Augustsson.", "Copyright (c) 2008 Hans Petter Selasky.",
     "1. Redistributions of source code must retain", "%%   SUCH DAMAGE."].each do |line|
      assert_includes header, line
    end
  end

  def test_the_lookup_matches_the_sources
    output, status = run_lookup(generated)
    assert status.success?, output
    assert_equal 'ok', output.strip
  end

  def test_each_seeded_fault_fails_the_lookup
    text = generated
    {
      'a lookup that ignores the range' => ["Low =< Release, Release =< High,\n", ''],
      "a generator that drops a row's last kind" => ['[capacity_is_count, ignore_csw_tag]', '[capacity_is_count]']
    }.each do |fault, (anchor, replacement)|
      assert_equal 1, text.scan(anchor).size, "seed anchor for #{fault} is not unique"
      output, status = run_lookup(text.sub(anchor) { replacement })
      refute status.success? && output.strip == 'ok', "#{fault}: the lookup passed"
    end
  end

  private

  def generated = Erx::UsbQuirks.generation(root: ROOT).files.fetch(Erx::UsbQuirks::OUTPUT)

  def run_lookup(text)
    Dir.mktmpdir('erx-usb-quirks-test') do |work|
      File.write(File.join(work, 'erx_usb_quirks.erl'), text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'),
                                       'erx_usb_quirks.erl', chdir: work, stdin_data: '')
      return [output, status] unless status.success?

      checks = CASES.map { |args, kinds| "#{kinds} = erx_usb_quirks:lookup(#{args})" }.join(', ')
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "try #{checks} of _ -> io:format(\"ok~n\"), halt(0) " \
                               'catch Class:Reason -> io:format("~p~n", [{Class, Reason}]), halt(1) end.',
                      chdir: work, stdin_data: '')
    end
  end
end
