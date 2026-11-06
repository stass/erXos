# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/medium_boot'

# What the harness adds to a boot from a release medium (tools/lib/erx/medium_boot.rb):
# the firmware's /chosen properties, merged into a tree by dtc, and the kernel's boot
# value line among the production checkpoints. Nothing boots here.
class MediumBootTest < Minitest::Test
  Boot = Erx::MediumBoot
  Choice = Erx::BootRecord::Choice

  def dtc(*arguments, input: nil)
    output, status = Open3.capture2e('dtc', '-q', *arguments, stdin_data: input.to_s)
    assert status.success?, output
    output
  end

  def test_the_properties_merge_into_the_trees_own_chosen_as_one_cell_each
    tree = "/dts-v1/;\n/ {\n\t#address-cells = <2>;\n\tchosen {\n\t\tstdout-path = \"/pl011@9000000\";\n\t};\n};\n"
    { a: 2, b: 3 }.each do |slot, partition|
      Dir.mktmpdir('erx-medium-boot-') do |directory|
        blob = File.join(directory, 'tree.dtb')
        dtc('-I', 'dts', '-O', 'dtb', '-o', blob, input: tree + Boot.chosen_source(Choice.new(slot: slot, offset: 0, length: 64)))
        listing = dtc('-I', 'dtb', '-O', 'dts', blob)
        assert_match(%r{chosen \{\n\t\tstdout-path = "/pl011@9000000";\n\n\t\tbootloader \{\n\t\t\tpartition = <0x0#{partition}>;\n\t\t\ttryboot = <0x00>;\n}, listing)
        assert_equal 1, listing.scan('chosen {').size
      end
    end
  end

  def test_the_boot_value_line_follows_the_image_line_and_must_name_the_slot
    points = [{ name: 'banner' }, { name: 'image-identity' }, { name: 'root-identity' }]
    merged = Boot.checkpoints(points, Choice.new(slot: :b, offset: 0, length: 64))
    assert_equal %w[banner image-identity boot-value root-identity], merged.map { |point| point.fetch(:name) }
    verify = merged.fetch(2).fetch(:verify)
    assert_match Boot::BOOT_VALUE, "erx: boot value normal slot b\r\n"
    verify.call("erx: boot value normal slot b\r\n")
    ["erx: boot value normal slot a\n", "erx: boot value unknown slot none\n", "erx: boot value trial slot b\n"].each do |line|
      assert_raises(Erx::Error, line) { verify.call(line) }
    end
    assert_raises(Erx::Error) { Boot.checkpoints([{ name: 'banner' }], Choice.new(slot: :a, offset: 0, length: 64)) }
  end
end
