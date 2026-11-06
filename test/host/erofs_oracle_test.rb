# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/erofs_oracle'

# The EROFS oracle's host side: the manifest parser over the guest's untrusted serial
# output and the comparison of two views (Erx::ErofsManifest), the Linux guest's
# package reader, initramfs writer and QEMU command line (Erx::LinuxGuest), and which
# outcomes pass (Erx::ErofsOracle). `tools/erx check-erofs-oracle` runs the whole oracle
# under QEMU; tools/fuzz/erofs_manifest.rb fuzzes the parser.
class ErofsOracleTest < Minitest::Test
  Manifest = Erx::ErofsManifest
  SUM = 'ab' * 32
  ROOT_LINE = 'entry 2f 41ed 60 0 0 3 0 36 -'
  FILE_LINE = "entry 2f736d616c6c 81a4 100 0 0 2 0 54 sha256:#{SUM}"
  LINK_LINE = 'entry 2f746f2d736d616c6c a1ff 5 0 0 1 0 61 link:736d616c6c'

  def manifest(*lines) = lines.map { |line| "erx-erofs: #{line}\r\n" }.join

  def self.image(*entries) = ['image 0', *entries, "end 0 #{entries.size}", 'done 1']

  def image(*entries) = self.class.image(*entries)

  def parse_one(*entries) = Manifest.parse(manifest(*image(*entries))).first

  def test_a_manifest_parses_into_entries_and_skips_the_kernels_lines
    text = "[    0.1] kernel says hello\n#{manifest('image 0', ROOT_LINE, FILE_LINE, LINK_LINE, 'end 0 3', 'refused 1 mount', 'done 2')}" \
           "[    0.2] reboot: Power down\n"
    views = Manifest.parse(text)
    assert_equal [3, nil], views.map { |view| view.entries&.size }
    assert_equal 'mount', views[1].refusal
    small = views[0].entries.fetch('/small')
    assert_equal [:regular, 0o100644, 100, 2, 54, [:sha256, SUM]],
                 [small.type, small.mode, small.size, small.nlink, small.inode, small.data]
    assert_equal [:symlink, [:link, 'small']], views[0].entries.fetch('/to-small').then { |link| [link.type, link.data] }
    assert_equal :directory, views[0].entries.fetch('/').type
  end

  def test_a_name_with_any_byte_but_nul_and_slash_survives
    name = "/a\nb\e[31m\xff".b
    entry = "entry #{name.unpack1('H*')} 81a4 0 0 0 1 0 7 sha256:#{SUM}"
    assert_equal [name], parse_one(entry).entries.keys
  end

  def test_errors_and_unreadable_metadata_are_kept_as_answers
    view = parse_one('entry 2f61 81a4 1 0 0 1 0 9 error:enotsup', 'entry 2f62 0 0 0 0 0 0 0 error:stat')
    assert_equal [[:error, 'enotsup'], [:error, 'stat']], view.entries.values.map(&:data)
    assert_equal :unknown, view.entries.fetch('/b').type
  end

  # Each line breaks one rule; the parser refuses the whole manifest.
  MALFORMED = {
    'no done line' => ['image 0', 'end 0 0'],
    'a line after done' => [*%w[image\ 0 end\ 0\ 0 done\ 1], 'done 1'],
    'an image out of order' => ['image 1', 'end 1 0', 'done 1'],
    'an end with the wrong count' => ['image 0', ROOT_LINE, 'end 0 2', 'done 1'],
    'an entry outside an image' => [ROOT_LINE, 'done 0'],
    'a repeated path' => ['image 0', FILE_LINE, FILE_LINE, 'end 0 2', 'done 1'],
    'a done count that differs' => ['image 0', 'end 0 0', 'done 2'],
    'an unknown keyword' => ['image 0', 'end 0 0', 'hello', 'done 1'],
    'a doubled space' => ['image 0', 'entry 2f  41ed 0 0 0 1 0 1 -', 'end 0 1', 'done 1'],
    'odd hex' => image('entry 2f6 41ed 0 0 0 1 0 1 -'),
    'upper-case hex' => image('entry 2F 41ed 0 0 0 1 0 1 -'),
    'a relative path' => image('entry 61 81a4 0 0 0 1 0 1 sha256:' + SUM),
    'a dot name' => image('entry 2f2e 41ed 0 0 0 1 0 1 -'),
    'a dot-dot name' => image('entry 2f612f2e2e 41ed 0 0 0 1 0 1 -'),
    'an empty name' => image('entry 2f612f 41ed 0 0 0 1 0 1 -'),
    'a NUL in a name' => image('entry 2f6100 81a4 0 0 0 1 0 1 sha256:' + SUM),
    'a path over PATH_MAX' => image("entry 2f#{'61' * 4096} 81a4 0 0 0 1 0 1 sha256:#{SUM}"),
    'a mode over 16 bits' => image('entry 2f 1041ed 0 0 0 1 0 1 -'),
    'a number with a leading zero' => image('entry 2f 41ed 01 0 0 1 0 1 -'),
    'a number over 64 bits' => image('entry 2f 41ed 18446744073709551616 0 0 1 0 1 -'),
    'a negative number' => image('entry 2f 41ed -1 0 0 1 0 1 -'),
    'a missing field' => image('entry 2f 41ed 0 0 0 1 0 -'),
    'a directory with a digest' => image("entry 2f 41ed 0 0 0 1 0 1 sha256:#{SUM}"),
    'a file without one' => image('entry 2f61 81a4 0 0 0 1 0 1 -'),
    'a link with a NUL' => image('entry 2f61 a1ff 1 0 0 1 0 1 link:00'),
    'an empty link' => image('entry 2f61 a1ff 1 0 0 1 0 1 link:'),
    'a short digest' => image('entry 2f61 81a4 0 0 0 1 0 1 sha256:abcd'),
    'a bad error reason' => image('entry 2f61 81a4 0 0 0 1 0 1 error:Bad!'),
    'unreadable metadata with data' => image('entry 2f61 0 0 0 0 0 0 0 -'),
    'a refusal inside an image' => ['image 0', 'refused 0 mount', 'end 0 0', 'done 1']
  }.freeze

  MALFORMED.each do |name, lines|
    define_method("test_refuses_#{name.tr(' -', '__')}") do
      assert_raises(Erx::Error) { Manifest.parse(manifest(*lines)) }
    end
  end

  def test_refuses_a_line_over_its_bound_and_too_many_images
    assert_raises(Erx::Error) { Manifest.parse(manifest('image 0', "entry 2f #{'0' * Manifest::MAX_LINE}", 'end 0 1', 'done 1')) }
    refusals = (0..Manifest::MAX_IMAGES).map { |index| "refused #{index} mount" }
    assert_raises(Erx::Error) { Manifest.parse(manifest(*refusals, "done #{refusals.size}")) }
    error = assert_raises(Erx::Error) { Manifest.parse("noise\n#{manifest('image 0', 'oops', 'done 1')}") }
    assert_match(/\Aline 3: /, error.message)
  end

  def view(*lines) = parse_one(*lines)

  def test_equal_views_agree_and_each_difference_is_named
    assert_empty Manifest.compare(linux: view(ROOT_LINE, FILE_LINE), reader: view(ROOT_LINE, FILE_LINE))
    differences = Manifest.compare(linux: view(ROOT_LINE, FILE_LINE, LINK_LINE),
                                   reader: view(ROOT_LINE.sub(' 36 ', ' 37 '), FILE_LINE.sub(SUM, 'cd' * 32)))
    assert_equal ['/: inode is 36 under Linux, 37 in the reader',
                  "/small: data is sha256:#{SUM} under Linux, sha256:#{'cd' * 32} in the reader",
                  '/to-small: only Linux sees it'], differences
    assert_equal ['/small: only the reader sees it'], Manifest.compare(linux: view(ROOT_LINE), reader: view(ROOT_LINE, FILE_LINE))
  end

  def test_a_difference_escapes_what_the_image_named
    hostile = "entry #{"/\e]0;pwned\a".unpack1('H*')} 81a4 0 0 0 1 0 7 sha256:#{SUM}"
    line = Manifest.compare(linux: view(ROOT_LINE), reader: view(ROOT_LINE, hostile)).first
    refute_match(/[\x00-\x1f\x7f]/, line)
    assert_includes line, '\\u{1b}]0;pwned\\u{7}'
  end

  def test_differences_beyond_the_shown_ones_are_counted
    files = (0...30).map { |index| "entry #{"/f#{index}".unpack1('H*')} 81a4 0 0 0 1 0 #{index + 1} sha256:#{SUM}" }
    differences = Manifest.compare(linux: view(ROOT_LINE), reader: view(ROOT_LINE, *files))
    assert_equal Manifest::SHOWN_DIFFERENCES + 1, differences.size
    assert_equal 'and 10 more differences', differences.last
  end

  def test_a_refusal_on_either_side_is_a_difference
    refused = Manifest.parse(manifest('refused 0 enotsup', 'done 1')).first
    assert_equal ['Linux did not mount the image'], Manifest.compare(linux: refused, reader: view(ROOT_LINE))
    assert_equal ['the reader refused the image: enotsup'], Manifest.compare(linux: view(ROOT_LINE), reader: refused)
  end

  # An image passes with the reader's refusal only when its expected refusal names
  # that error; the fixtures' expectations come from tools/erofs_fixtures.rb.
  def test_only_the_listed_fixtures_pass_refused
    oracle = Erx::ErofsOracle.new(root: Dir.pwd, runner: nil, environment: {}, guest: nil, erofs: nil)
    fixtures = Erx::ErofsOracle.fixtures('/root')
    lz4 = fixtures.fetch('test/fixtures/erofs/lz4.img')
    assert_equal ['/root/test/fixtures/erofs/lz4.img', 'enotsup'], [lz4.path, lz4.refusal]
    assert_nil fixtures.fetch('test/fixtures/erofs/compact.img').refusal
    release = Erx::ErofsOracle::Image.new(path: '/release.erofs', refusal: nil)
    linux = view(ROOT_LINE)
    refused = ->(reason) { Manifest.parse(manifest("refused 0 #{reason}", 'done 1')).first }
    outcome = ->(image, reason) { oracle.send(:outcome, 'image', image, linux, refused.call(reason)) }
    assert outcome.call(lz4, 'enotsup').passed?
    refute outcome.call(lz4, 'eio').passed?
    refute outcome.call(release, 'enotsup').passed?
    assert oracle.send(:outcome, 'release', release, linux, view(ROOT_LINE)).passed?
    unmounted = oracle.send(:outcome, 'release', release, refused.call('mount'), view(ROOT_LINE))
    assert_nil unmounted.files
    refute unmounted.passed?
  end

  Guest = Erx::LinuxGuest

  def ar(members)
    "!<arch>\n" + members.map do |name, bytes|
      header = format('%-16s%-12d%-6d%-6d%-8s%-10d`', "#{name}/", 0, 0, 0, '100644', bytes.bytesize) + "\n"
      header + bytes + ("\n" * (bytes.bytesize & 1))
    end.join
  end

  def test_the_package_reader_finds_a_member_after_an_odd_one
    package = ar([['debian-binary', "2.0\n"], ['control.tar.xz', 'odd'], ['data.tar.xz', 'data bytes']])
    assert_equal 'data bytes', Guest::Ar.member(package, 'data.tar.xz')
    assert_raises(Erx::Error) { Guest::Ar.member(package, 'missing') }
    assert_raises(Erx::Error) { Guest::Ar.member('not an archive', 'data.tar.xz') }
    assert_raises(Erx::Error) { Guest::Ar.member(package.byteslice(0, package.bytesize - 3), 'data.tar.xz') }
    assert_raises(Erx::Error) { Guest::Ar.member(package.sub('10        `', '1x        `'), 'data.tar.xz') }
  end

  # The host's own cpio, an independent reader of the format, lists and extracts what
  # the writer packed, byte for byte, and the same entries give the same archive.
  def test_the_initramfs_is_a_newc_archive_the_hosts_cpio_reads
    entries = [['bin', 0o40755, nil], ['bin/tool', 0o100755, "\x7fELF\x00\x01".b], ['init', 0o100755, "#!/bin/sh\n"],
               ['odd', 0o100644, 'abc']]
    archive = Guest::Cpio.archive(entries)
    assert_equal archive, Guest::Cpio.archive(entries)
    assert_equal 0, archive.bytesize % 4
    Dir.mktmpdir('erofs-oracle-cpio') do |directory|
      listing, status = Open3.capture2e('cpio', '-it', stdin_data: archive, chdir: directory)
      assert status.success?, listing
      assert_equal %w[bin bin/tool init odd], listing.lines.map(&:chomp).reject { |line| line.include?('block') }
      output, status = Open3.capture2e('cpio', '-id', stdin_data: archive, chdir: directory)
      assert status.success?, output
      assert_equal "\x7fELF\x00\x01".b, File.binread(File.join(directory, 'bin/tool'))
      assert File.executable?(File.join(directory, 'init'))
    end
  end

  def test_the_guest_has_no_network_and_only_read_only_disks
    guest = Guest::BootFiles.new(kernel: '/k', initramfs: '/i')
    argv = Guest.argv(guest, images: ['/a.img', '/odd,name.img'], accel: 'hvf')
    assert_equal 'qemu-system-aarch64', argv.first
    %w[-nodefaults -no-reboot].each { |flag| assert_includes argv, flag }
    assert_equal 'none', argv[argv.index('-nic') + 1]
    refute(argv.any? { |word| word.include?('netdev') || word.start_with?('virtio-net') })
    drives = argv.each_cons(2).select { |flag, _| flag == '-drive' }.map(&:last)
    assert_equal ['if=none,id=image0,format=raw,readonly=on,file=/a.img',
                  'if=none,id=image1,format=raw,readonly=on,file=/odd,,name.img'], drives
    assert_includes argv, 'virtio-blk-pci,drive=image1,serial=erx-image-1'
    assert_match(/ erx\.images=2\z/, argv[argv.index('-append') + 1])
    assert_raises(Erx::Error) { Guest.argv(guest, images: [], accel: 'hvf') }
    assert_raises(Erx::Error) { Guest.argv(guest, images: ['/a'], accel: 'kvm') }
    assert_raises(Erx::Error) { Guest.argv(guest, images: ['nbd:host:1/x'], accel: 'hvf') }
  end
end
