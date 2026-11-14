# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/dependencies'

# The USB keyboard map of the ABI file (abi/formats/hid.txt's translation
# hid_keyboard_key) against FreeBSD 15.1's evdev_usb_scancodes in
# sys/dev/evdev/evdev_utils.c at deps.lock's freebsd-evdev-utils pin
# (docs/design-usb.md, "The usage table"). The pinned file is read as data:
# the table's 256 initializers, each a KEY_ name or NONE, by usage.
class AbiHidUsageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TABLE = /\bevdev_usb_scancodes\[256\]\s*=\s*\{(?<body>[^}]*)\};/
  ENTRY = /\A(?:NONE|KEY_[A-Z0-9_]+)\z/
  SEEDED_LINE = /^  map 0x04 key_a$/

  def test_keyboard_map_matches_freebsd
    assert_equal freebsd, keyboard_map(ROOT)
  end

  # Seeded fault: a map whose usage 04h (a and A) names key_b is well formed,
  # since key_b is an evdev code, so only the comparison with FreeBSD refuses it.
  def test_comparison_catches_a_changed_entry
    Dir.mktmpdir('erx-abi-hid-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/formats/hid.txt')
      text = File.read(path)
      assert_match SEEDED_LINE, text
      File.write(path, text.sub(SEEDED_LINE, '  map 0x04 key_b'))
      table = keyboard_map(root)
      assert_equal 'key_b', table.fetch(0x04)
      refute_equal freebsd, table
    end
  end

  private

  # FreeBSD's table as usage to evdev member name, KEY_A as key_a; NONE,
  # FreeBSD's KEY_RESERVED, is a usage with no code and no entry.
  def freebsd
    _, path = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-evdev-utils')
    body = File.read(path).match(TABLE)&.[](:body) || flunk('evdev_usb_scancodes not found')
    entries = body.gsub(%r{/\*.*?\*/}m, '').split(',').map(&:strip).reject(&:empty?)
    assert_equal 256, entries.size
    entries.each { |entry| assert_match ENTRY, entry }
    entries.each_with_index.reject { |entry, _| entry == 'NONE' }.to_h { |entry, usage| [usage, entry.downcase] }
  end

  # The translation hid_keyboard_key of the ABI files beneath root, as the
  # model checked it: usage to evdev member name.
  def keyboard_map(root)
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64'))
    schema.translations.find { |translation| translation.name == 'hid_keyboard_key' }.map
  end
end
