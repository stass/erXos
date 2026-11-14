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
  DOMAIN = Erx::MediumBoot::Domain.new(runtime: 41, jit: 42, release: 7, release_files: 30)
  IMAGE = Erx::MediumBoot::SlotImage.new(format: 2, slot_offset: 128 << 20, length: 8192)

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
        # The device tree compiler's listing, either dtc's (Homebrew's, or FreeBSD's own): they
        # differ only in blank lines and in how many digits a cell is printed with.
        assert_match(%r{chosen \{\s*stdout-path = "/pl011@9000000";\s*bootloader \{\s*partition = <0x0?#{partition}>;\s*tryboot = <0x0{1,2}>;\n},
                     listing)
        assert_equal 1, listing.scan('chosen {').size
      end
    end
  end

  def test_the_boot_value_line_follows_the_image_line_and_must_name_the_slot
    points = [{ name: 'banner' }, { name: 'image-identity' }, { name: 'root-identity' }, { name: 'release-shell' }]
    merged = Boot.checkpoints(points, Choice.new(slot: :b, offset: 0, length: 64), release: release, domain: DOMAIN, image: IMAGE)
    assert_equal %w[banner image-identity boot-value root-identity release-shell erlang-shell image-md5 crc32c domain-lib] +
                 Boot::COMMAND_SHELL.map { |point| point.fetch(:name) }, merged.map { |point| point.fetch(:name) }
    typed = merged.to_h { |point| [point.fetch(:name), point[:type]] }
    assert_equal "erl\r", typed.fetch('release-shell')
    assert_match(/\AImWait=fun /, typed.fetch('erlang-shell'))
    assert_equal "#{Boot.domain_lib_expression(DOMAIN)}\r", typed.fetch('crc32c')
    assert_equal "erx_shell:start().\r", typed.fetch('domain-lib')
    assert_match merged.find { |point| point.fetch(:name) == 'erlang-shell' }.fetch(:pattern),
                 "Eshell V16.0 (type help(). for help)\r\n"
    verify = merged.fetch(2).fetch(:verify)
    assert_match Boot::BOOT_VALUE, "erx: boot value normal slot b\r\n"
    verify.call("erx: boot value normal slot b\r\n")
    ["erx: boot value normal slot a\n", "erx: boot value unknown slot none\n", "erx: boot value trial slot b\n"].each do |line|
      assert_raises(Erx::Error, line) { verify.call(line) }
    end
    assert_raises(Erx::Error) { Boot.checkpoints([{ name: 'banner' }], Choice.new(slot: :a, offset: 0, length: 64), release: release, domain: DOMAIN, image: IMAGE) }
    assert_raises(Erx::Error) { Boot.checkpoints(points[0..2], Choice.new(slot: :a, offset: 0, length: 64), release: release, domain: DOMAIN, image: IMAGE) }
  end

  # The shell reads stdlib's lists module from the image at the storage node, which it
  # places from the slot image's extent, and only its packed MD5 passes; a release without
  # the module has nothing to read.
  def test_the_shell_reads_a_release_file_from_the_image_and_must_print_its_md5
    shell, answer = Boot.image_checkpoints({ name: 'erlang-shell', pattern: /\AEshell V/n }, release, IMAGE)
    assert_match %r{erpc:call\('storage@erxos',fun\(\)->}, shell.fetch(:type)
    assert_includes shell.fetch(:type), 'format=>2,data_bytes=>8192,extents=>[{134217728,8192}]'
    assert_match %r{file:read_file\("/images/release/system/lib/stdlib-7\.0/ebin/lists\.beam"\)}, shell.fetch(:type)
    assert shell.fetch(:type).end_with?(".\r")
    verify = answer.fetch(:verify)
    hex = Digest::MD5.file(@lists).hexdigest.upcase
    assert_match answer.fetch(:pattern), "2> {image_md5,<<\"#{hex}\">>}\r\n"
    verify.call("2> {image_md5,<<\"#{hex}\">>}\r\n")
    verify.call("{image_md5,<<\"#{hex}\">>}\n")
    ["{image_md5,<<\"#{hex.downcase}\">>}\n", "{image_md5,{error,enoent}}\n", "{image_md5,<<\"00\">>}\n",
     "{image_md5,{error,{erpc,noconnection}}}\n"].each do |line|
      assert_raises(Erx::Error, line) { verify.call(line) }
    end
    assert_raises(Erx::Error) { Boot.image_checkpoints({ name: 'erlang-shell' }, release.take(1), IMAGE) }
  end

  # After the image's answer the shell runs the CRC-32C primitive, and only the answer
  # the bitwise model gives passes: RFC 3720's check value, the chunked value, and the
  # refusal of one call over 65536 bytes.
  def test_the_shell_runs_the_crc32c_primitive_and_must_print_the_models_values
    merged = Boot.checkpoints([{ name: 'image-identity' }, Erx::ProductionImage::Run::RELEASE_SHELL],
                              Choice.new(slot: :a, offset: 0, length: 64), release: release, domain: DOMAIN, image: IMAGE)
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

  # The medium manifest gives the system principal room for two more domains, drops its
  # session template, appends the configured one, and leaves every other field of the site
  # manifest as it was.
  def test_the_medium_manifest_has_room_for_two_domains_and_changes_nothing_else
    site = site_manifest
    grown = Boot.manifest(site)
    growth = 2 * (Boot::DOMAIN_MEMORY + Boot::DOMAIN_OUTER)
    memory, root_memory, domains = [/^principal system\n  memory ([0-9]+)$/, /^  root_memory ([0-9]+)$/, /^  max_domains ([0-9]+)$/]
                                   .map { |pattern| Integer(site[pattern, 1], 10) }
    assert_equal ["principal system\n  memory #{memory + growth}", "  root_memory #{root_memory + growth}",
                  "  domains #{domains + 2}", "  max_domains #{domains + 2}"],
                 [grown[/^principal system\n  memory [0-9]+$/], grown[/^  root_memory [0-9]+$/],
                  grown[/^principal system\n(?:  .*\n)*?(  domains [0-9]+)$/, 1], grown[/^  max_domains [0-9]+$/]]
    assert_equal site[/^  max_connections [0-9]+$/], grown[/^  max_connections [0-9]+$/]
    sessionless = Erx::ProductionImage.without_sessions(site)
    refute_match(/^session /, sessionless)
    refute_match(/^  grantee @session\./, sessionless)
    # The session template's 5 lines, and the facets granted to it: the 10 of data_session,
    # the 9 of net, the 9 of inspect and the 9 of apps.
    assert_equal 5 + 10 + 9 + 9 + 9, site.lines.size - sessionless.lines.size
    assert_equal 4, sessionless.lines.zip(grown.lines).count { |left, right| left != right }
    assert_equal sessionless.lines.size, grown.lines.size - Boot::DOMAIN_ROW.lines.size
    assert grown.end_with?(Boot::DOMAIN_ROW)
    assert_raises(Erx::Error) { Boot.manifest(site.sub(/^  max_domains [0-9]+\n/, '')) }
  end

  # The footprint cell's manifest has room for its three domains and sets the system domain's
  # /tmp cap; its expression creates one domain per step, booting the step's script, the
  # last with a tmp cap, and says what it measures.
  def test_the_footprint_cell_has_room_for_its_domains_and_one_step_each
    site = site_manifest
    cell = Boot::Footprint
    system_tmp = /^runtime_limits system\n(?:  .*\n)*?  tmp ([0-9]+)$/
    grown = cell.manifest(site, system_tmp: 8_388_608)
    assert_equal 8_388_608, grown[system_tmp, 1].to_i
    figure = ->(text, pattern) { text[pattern, 1].to_i }
    # The figures grow from the site manifest's.
    assert_equal figure.(site, /^  max_domains ([0-9]+)$/) + 3, figure.(grown, /^  max_domains ([0-9]+)$/)
    growth = 3 * (cell::MEMORY + Boot::DOMAIN_OUTER)
    assert_equal figure.(site, /^  root_memory ([0-9]+)$/) + growth, figure.(grown, /^  root_memory ([0-9]+)$/)
    assert_equal figure.(site, /^principal system\n  memory ([0-9]+)$/) + growth,
                 figure.(grown, /^principal system\n  memory ([0-9]+)$/)
    assert_equal %w[storage network bare blk net], grown.scan(/^domain ([a-z]+)$/).flatten
    without_tmp = site.sub(/^(runtime_limits system\n(?:  .*\n)*?)  tmp [0-9]+\n/, '\1')
    assert_raises(Erx::Error) { cell.manifest(without_tmp, system_tmp: 0) }
    runs = cell::RELEASES.keys.to_h { |name| [name, { 'entry' => name.size, 'files' => 7 }] }
    expression = cell.expression(runs: runs, runtime: 41)
    assert_equal cell::STEPS.size, expression.scan(/\{<<"[a-z0-9-]+">>,<<"[a-z]+">>,[0-9]+,7,[0-9]+\}/).size
    assert_match(/<<"bare-tmp4">>,<<"bare">>,4,7,4194304\}/, expression)
    assert_match(/\.\z/, expression)
  end

  # The create map names the archive's indexes, and the answer is the one the configured
  # domain's halt and the cell's halt, stop, kill, BeamAsm halt and faceted halt give; a line with another
  # end, a restarted configured domain or a refused create does not pass.
  def test_the_domain_cell_names_the_archives_indexes_and_must_see_every_end
    expression = Boot.domain_lib_expression(DOMAIN)
    assert_match(/id=>17,name=><<"cell">>,principal=>1,runtime=>41,release=>7,release_files=>30,memory=>167772160,outer=>1048576,/, expression)
    # The library refuses an id at or below the system domain's, so the service's ids
    # start above it; the shell's own calls of the library are refused.
    header = File.read(File.expand_path('../../include/erx/dom.h', __dir__))
    assert_equal Integer(header[/^#define\s+ERX_DOM_SYSTEM_ID\s+([0-9]+)u$/, 1], 10), Boot::SYSTEM_DOMAIN_ID
    assert_includes expression, 'DlNotCreate=Lib:create(Spec)'
    assert_includes expression, 'DlNotService=Lib:configured(17,0,self())'
    assert_includes expression, 'DlNotStop=Lib:stop(5,0)'
    assert expression.start_with?('io:format("~0p~n",[(fun(Lib,Spec,JitFields,FacetFields,UpFields)->DlDeath=fun(Id)->')
    # The BeamAsm domain names the BeamAsm image and halts 0 only as BeamAsm.
    assert_match(/\},\#\{runtime=>42,args=><<"--",0,.*"-eval",0,"erlang:halt\(case erlang:system_info\(emu_flavor\) of jit->0;_->2 end\)",0>>\},/,
                 expression)
    # The stopped and the killed domain stay up as nodes: no -eval, so no halt of their own.
    up = expression[/\},(\#\{args=><<[^>]*>>\})\)\]\)\.\z/, 1]
    assert_includes up, '"-proto_dist",0,"erx",0>>'
    refute_includes up, '-eval'
    assert_match(/args=><<"--",0,"-root",0,.*"-eval",0,"erlang:halt\(length\(.*init:get_argument\(sname\){6}\+100-lists:sum\(\[100\|\|\{S,_\}<-\[init:script_id\(\)\],S=:=atom_to_list\(erts\)\]\)\)",0>>,env=><<>>/,
                 expression)
    refute_match(/[^\x20-\x7e]/, expression)
    merged = Boot.checkpoints([{ name: 'image-identity' }, Erx::ProductionImage::Run::RELEASE_SHELL],
                              Choice.new(slot: :a, offset: 0, length: 64), release: release, domain: DOMAIN, image: IMAGE)
    point = merged.find { |each| each.fetch(:name) == 'domain-lib' }
    refute_match point.fetch(:pattern), "4> #{expression}\r\n"
    point.fetch(:verify).call("4> #{Boot::DOMAIN_LIB_ANSWER}\r\n")
    [Boot::DOMAIN_LIB_ANSWER.sub('{halt,0}', '{halt,1}'), Boot::DOMAIN_LIB_ANSWER.sub('{error,einval}', '{error,enotsup}'),
     Boot::DOMAIN_LIB_ANSWER.sub('[{5,{halt,0}}]', '[{8,{halt,0}},{5,{halt,0}}]'),
     Boot::DOMAIN_LIB_ANSWER.sub("{#{Boot::DOMAIN_IDS[2]},ok,killed}", '{error,quota}'),
     Boot::DOMAIN_LIB_ANSWER.sub("{domain_down,#{Boot::DOMAIN_IDS[3]},{halt,0}}", "{domain_down,#{Boot::DOMAIN_IDS[3]},crash}"),
     Boot::DOMAIN_LIB_ANSWER.sub(/true\}\z/, 'false}')].each do |line|
      assert_raises(Erx::Error, line) { point.fetch(:verify).call("#{line}\n") }
    end
  end

  private

  # CRC-32C bit by bit, seeded with all ones and inverted at the end (RFC 3720).
  def crc32c(bytes)
    bytes.each_byte.reduce(0xFFFFFFFF) do |crc, byte|
      8.times.reduce(crc ^ byte) { |bits, _| bits.odd? ? (bits >> 1) ^ 0x82F63B78 : bits >> 1 }
    end ^ 0xFFFFFFFF
  end

  # The website's manifest, which the medium boots start from.
  def site_manifest
    root = File.expand_path('../..', __dir__)
    Erx::Platform.development(root).site_manifest_source(root)
  end

  # Two release entries, the second the module the shell reads, whose bytes are this file's.
  def release
    @lists = __FILE__
    [{ 'path' => 'system/lib/stdlib-7.0/ebin/lists.app', 'artifact' => __FILE__ },
     { 'path' => 'system/lib/stdlib-7.0/ebin/lists.beam', 'artifact' => @lists }]
  end
end
