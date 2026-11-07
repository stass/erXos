# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest/md5'
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
    points = [{ name: 'banner' }, { name: 'image-identity' }, { name: 'root-identity' }, { name: 'release-shell' }]
    merged = Boot.checkpoints(points, Choice.new(slot: :b, offset: 0, length: 64), release: release)
    assert_equal %w[banner image-identity boot-value root-identity release-shell image-md5 crc32c] +
                 Boot::COMMAND_SHELL.map { |point| point.fetch(:name) }, merged.map { |point| point.fetch(:name) }
    assert_equal "erx_shell:start().\r", merged.find { |point| point.fetch(:name) == 'crc32c' }.fetch(:type)
    verify = merged.fetch(2).fetch(:verify)
    assert_match Boot::BOOT_VALUE, "erx: boot value normal slot b\r\n"
    verify.call("erx: boot value normal slot b\r\n")
    ["erx: boot value normal slot a\n", "erx: boot value unknown slot none\n", "erx: boot value trial slot b\n"].each do |line|
      assert_raises(Erx::Error, line) { verify.call(line) }
    end
    assert_raises(Erx::Error) { Boot.checkpoints([{ name: 'banner' }], Choice.new(slot: :a, offset: 0, length: 64), release: release) }
    assert_raises(Erx::Error) { Boot.checkpoints(points[0..2], Choice.new(slot: :a, offset: 0, length: 64), release: release) }
  end

  # The shell reads stdlib's lists module from /images/release, and only its packed MD5
  # passes; a release without the module has nothing to read.
  def test_the_shell_reads_a_release_file_from_the_image_and_must_print_its_md5
    shell, answer = Boot.image_checkpoints({ name: 'release-shell', pattern: /\AEshell V/n }, release)
    assert_match %r{file:read_file\("/images/release/system/lib/stdlib-7\.0/ebin/lists\.beam"\)}, shell.fetch(:type)
    assert shell.fetch(:type).end_with?(".\r")
    verify = answer.fetch(:verify)
    hex = Digest::MD5.file(@lists).hexdigest.upcase
    assert_match answer.fetch(:pattern), "2> {image_md5,<<\"#{hex}\">>}\r\n"
    verify.call("2> {image_md5,<<\"#{hex}\">>}\r\n")
    verify.call("{image_md5,<<\"#{hex}\">>}\n")
    ["{image_md5,<<\"#{hex.downcase}\">>}\n", "{image_md5,{error,enoent}}\n", "{image_md5,<<\"00\">>}\n"].each do |line|
      assert_raises(Erx::Error, line) { verify.call(line) }
    end
    assert_raises(Erx::Error) { Boot.image_checkpoints({ name: 'release-shell' }, release.take(1)) }
  end

  # After the image's answer the shell runs the CRC-32C primitive, and only the answer
  # the bitwise model gives passes: RFC 3720's check value, the chunked value, and the
  # refusal of one call over 65536 bytes.
  def test_the_shell_runs_the_crc32c_primitive_and_must_print_the_models_values
    merged = Boot.checkpoints([{ name: 'image-identity' }, { name: 'release-shell', pattern: /\AEshell V/n }],
                              Choice.new(slot: :a, offset: 0, length: 64), release: release)
    image_answer, crc = %w[image-md5 crc32c].map { |name| merged.find { |point| point.fetch(:name) == name } }
    assert_equal "#{Boot::CRC32C_EXPRESSION}\r", image_answer.fetch(:type)
    assert_equal '{crc32c,"%X","%X",badarg}' % [crc32c('123456789'), crc32c('erXos' * 20_000)], Boot::CRC32C_ANSWER
    assert_equal 0xE3069283, crc32c('123456789')
    refute_match crc.fetch(:pattern), "3> #{Boot::CRC32C_EXPRESSION}\r\n"
    assert_match crc.fetch(:pattern), "3> #{Boot::CRC32C_ANSWER}\r\n"
    crc.fetch(:verify).call("3> #{Boot::CRC32C_ANSWER}\r\n")
    crc.fetch(:verify).call("#{Boot::CRC32C_ANSWER}\n")
    ['{crc32c,"E3069283","2D78517E",badarg}', '{crc32c,"E3069283","2D78517F",3}',
     "{crc32c,{'EXIT',{undef,[]}}}"].each do |line|
      assert_raises(Erx::Error, line) { crc.fetch(:verify).call("#{line}\n") }
    end
  end

  private

  # CRC-32C bit by bit, seeded with all ones and inverted at the end (RFC 3720).
  def crc32c(bytes)
    bytes.each_byte.reduce(0xFFFFFFFF) do |crc, byte|
      8.times.reduce(crc ^ byte) { |bits, _| bits.odd? ? (bits >> 1) ^ 0x82F63B78 : bits >> 1 }
    end ^ 0xFFFFFFFF
  end

  # Two release entries, the second the module the shell reads, whose bytes are this file's.
  def release
    @lists = __FILE__
    [{ 'path' => 'system/lib/stdlib-7.0/ebin/lists.app', 'artifact' => __FILE__ },
     { 'path' => 'system/lib/stdlib-7.0/ebin/lists.beam', 'artifact' => @lists }]
  end
end
