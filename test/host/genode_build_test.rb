# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rubygems/package'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/lib/erx/genode_build'

# `tools/erx build genode` (docs/design-bench.md, "Genode's guest"): the run script erXos
# writes for Genode's run tool, the reader of a tool package's data archive, the check of
# every archive the engine extracts at the container's root, and the plan of docker
# commands. The container itself runs only in the build on the x86-64 host.
class GenodeBuildTest < Minitest::Test
  ENDPOINT = 'unix:///run/engine.sock'
  IMAGE = "example.org/image@sha256:#{'a' * 64}"

  def plan
    Erx::GenodeBuild.plan(endpoint: ENDPOINT, name: 'erx-genode-build-1', image: IMAGE, inputs: '/w/inputs',
                          tree: '/trees/genode', directory: 'genode-d18ee9e', writable: '/w/writable',
                          archives: ['/w/toolchain.checked.tar', '/w/tcl.checked.tar'],
                          archive: '/w/out.tar', jobs: 8, toolchain: '25.05')
  end

  # The run script carries the program's arguments into init's configuration, and only
  # words: a brace or a space would end the Tcl word or the configuration's attribute.
  def test_the_run_script_gives_the_program_its_arguments_and_refuses_other_text
    script = Erx::GenodeBuild.run_script(arguments: %w[posix 2])
    assert_includes script, 'build { app/erx_peer_bench }'
    assert_includes script, "    + libc | stdout: /dev/log | stderr: /dev/log\n    + arg | : erx_peer_bench\n    + arg | : posix\n    + arg | : 2\n-\n}"
    assert script.start_with?("create_boot_directory\n")
    assert script.end_with?("build_boot_image [build_artifacts]\n")
    ['posix }', 'a b', "x\n", '[exec]'].each do |word|
      assert_raises(Erx::Error) { Erx::GenodeBuild.run_script(arguments: [word]) }
    end
  end

  def ar(members)
    members.reduce(+"!<arch>\n") do |archive, (name, bytes)|
      header = format('%-16s%-12s%-6s%-6s%-8s%-10d`', "#{name}/", '0', '0', '0', '100644', bytes.bytesize) + "\n"
      archive << header << bytes << (bytes.bytesize.odd? ? "\n" : '')
    end
  end

  # Only data.tar.xz is taken: the control archive, which holds the maintainer scripts,
  # never leaves the package.
  def test_a_packages_data_archive_alone_is_taken
    package = ar([['debian-binary', "2.0\n"], ['control.tar.xz', 'CONTROL'], ['data.tar.xz', 'DATA!']])
    assert_equal 'DATA!', Erx::GenodeBuild.data_archive(package)
    assert_raises(Erx::Error) { Erx::GenodeBuild.data_archive(ar([['control.tar.xz', 'CONTROL']])) }
    assert_raises(Erx::Error) { Erx::GenodeBuild.data_archive(package.sub('5         `', '9999      `')) }
    assert_raises(Erx::Error) { Erx::GenodeBuild.data_archive('PK') }
  end

  def tar
    io = StringIO.new(+''.b)
    Gem::Package::TarWriter.new(io) { |writer| yield writer, io }
    io.rewind
    io
  end

  def raw(writer_io, name, typeflag, linkname: '')
    header = Gem::Package::TarHeader.new(name: name, size: 0, mode: 0o644, typeflag: typeflag, prefix: '',
                                         linkname: linkname)
    writer_io.write(header.to_s)
  end

  def rewrite(io, prefix:, output: StringIO.new(+''.b))
    Erx::CheckedTar.rewrite(io, output, prefix: prefix, label: 'a package')
  end

  def check(prefix: 'usr/', &block) = rewrite(tar(&block), prefix: prefix)

  # A Debian package's tree under ./usr/, with links that stay inside it, is accepted and
  # written afresh as ustar: names without "./", the root directory left out, owner 0:0.
  def test_a_tree_under_its_prefix_with_inner_links_is_written_afresh
    output = StringIO.new(+''.b)
    count = rewrite(tar do |writer, io|
      writer.mkdir('./', 0o755)
      writer.mkdir('./usr/bin', 0o755)
      writer.add_file_simple('./usr/bin/tclsh8.6', 0o755, 2) { |file| file.write('#!') }
      writer.add_symlink('./usr/bin/tclsh', 'tclsh8.6', 0o777)
      writer.add_symlink('./usr/lib/x/libtcl.so', '../../lib/libtcl8.6.so', 0o777)
      raw(io, './usr/bin/tclsh-hard', '1', linkname: './usr/bin/tclsh8.6')
    end, prefix: 'usr/', output: output)
    assert_equal 5, count
    output.rewind
    entries = Gem::Package::TarReader.new(output).map do |entry|
      header = entry.header
      [header.name, header.typeflag, header.linkname, header.uid, header.magic, entry.read.to_s]
    end
    assert_equal [['usr/bin/', '5', '', 0, 'ustar', ''], ['usr/bin/tclsh8.6', '0', '', 0, 'ustar', '#!'],
                  ['usr/bin/tclsh', '2', 'tclsh8.6', 0, 'ustar', ''],
                  ['usr/lib/x/libtcl.so', '2', '../../lib/libtcl8.6.so', 0, 'ustar', ''],
                  ['usr/bin/tclsh-hard', '1', 'usr/bin/tclsh8.6', 0, 'ustar', '']], entries
  end

  # What the engine would extract beyond the tools' directory, or what could rename an
  # entry after the check, is refused: each case alone.
  def test_entries_outside_the_prefix_links_out_of_it_devices_and_extended_headers_are_refused
    cases = {
      'a file elsewhere' => ->(writer, _io) { writer.add_file_simple('./etc/passwd', 0o644, 0) { nil } },
      'a dot-dot path' => ->(writer, _io) { writer.add_file_simple('./usr/../etc/passwd', 0o644, 0) { nil } },
      'an absolute link' => ->(writer, _io) { writer.add_symlink('./usr/bin/sh', '/bin/sh', 0o777) },
      'a link climbing out' => ->(writer, _io) { writer.add_symlink('./usr/bin/p', '../../etc/passwd', 0o777) },
      'a hard link out' => ->(_writer, io) { raw(io, './usr/bin/p', '1', linkname: './etc/passwd') },
      'a device' => ->(_writer, io) { raw(io, './usr/dev', '3') },
      'an extended header' => ->(_writer, io) { raw(io, './usr/PaxHeader', 'x') },
      'another prefix' => ->(writer, _io) { writer.mkdir('./usr/share', 0o755) },
      'a long name out' => lambda do |writer, io|
        name = "/etc/passwd\0"
        io.write(Gem::Package::TarHeader.new(name: '././@LongLink', size: name.bytesize, mode: 0o644, typeflag: 'L',
                                             prefix: '').to_s, name.ljust(512, "\0"))
        writer.add_file_simple('./usr/bin/x', 0o644, 0) { nil }
      end
    }
    cases.each do |label, entry|
      prefix = label == 'another prefix' ? 'usr/local/genode/tool/' : 'usr/'
      assert_raises(Erx::Error, label) { check(prefix: prefix) { |writer, io| entry.call(writer, io) } }
    end
  end

  # One raw tar header block: fields at their ustar offsets, magic as given ("" for a V7
  # header), and its checksum.
  def block(name, typeflag: '0', size: 0, linkname: '', magic: "ustar\0", version: '00', prefix: '')
    fields = [[0, name], [100, '0000644'], [108, '0000000'], [116, '0000000'], [124, format('%011o', size)],
              [136, '00000000000'], [156, typeflag], [157, linkname], [257, magic], [263, version], [345, prefix]]
    header = fields.each_with_object("\0".b * 512) { |(offset, text), bytes| bytes[offset, text.bytesize] = text.b }
    header[148, 8] = ' ' * 8
    header[148, 8] = format('%06o', header.sum(0)) + "\0 "
    header
  end

  # Archives the host reader and the engine's could read differently, each alone: a V7
  # header whose prefix field the host would join to its name, a name hiding bytes after
  # a NUL, a link that climbs out through another link, and an archive cut before its end.
  def test_archives_read_two_ways_are_refused
    end_blocks = "\0".b * 1024
    cases = {
      'a V7 prefix' => block('evil', magic: '', version: '', prefix: 'usr/bin') + end_blocks,
      'a NUL in a name' => block("usr/bin/x\0y") + end_blocks,
      'a link out through a link' => block('usr/a/x', typeflag: '2', linkname: '.') +
                                     block('usr/a/y', typeflag: '2', linkname: 'x/x/x/x/../../../..') + end_blocks,
      'no end block' => block('usr/bin/x')
    }
    cases.each do |label, bytes|
      assert_raises(Erx::Error, label) { rewrite(StringIO.new(bytes), prefix: 'usr/') }
    end
  end

  # The container is created confined, as the non-root user, under env -i with the tool
  # chain on its path; archives reach it on standard input and trees by copy, never by a
  # mount, and the export is the only thing streamed out.
  def test_the_container_is_confined_and_fed_only_by_copies
    steps = plan
    create = steps.fetch(:create).argv
    confinement = Erx::OracleContainer::CONFINEMENT
    assert_equal confinement, create[create.index('--network'), confinement.size]
    { '--user' => '1000:1000', '--pull' => 'never', '--platform' => 'linux/amd64', '--memory' => '16g',
      '--memory-swap' => '16g', '--entrypoint' => '/usr/bin/env' }.each do |flag, value|
      assert_equal value, create[create.index(flag) + 1], flag
    end
    refute create.any? { |argument| argument.start_with?('--mount', '--volume', '-v', '--privileged', '--env') }
    assert_includes create, 'PATH=/usr/local/genode/tool/25.05/bin:/usr/local/bin:/usr/bin:/bin'
    assert_equal ['/bin/sh', '/tmp/inputs/build.sh', '8', '/tmp/genode-d18ee9e'], create.last(4)
    assert_equal [['/w/toolchain.checked.tar', ['cp', '-', 'erx-genode-build-1:/']], ['/w/tcl.checked.tar', ['cp', '-', 'erx-genode-build-1:/']]],
                 steps.fetch(:extracts).map { |step| [step.stdin, step.argv.last(3)] }
    assert_equal [['/trees/genode', 'erx-genode-build-1:/tmp/genode-d18ee9e'], ['/w/writable/.', 'erx-genode-build-1:/tmp/genode-d18ee9e'],
                  ['/w/inputs', 'erx-genode-build-1:/tmp/inputs']], steps.fetch(:copies).map { |step| step.argv.last(2) }
    assert_equal '/w/out.tar', steps.fetch(:export).stdout
  end

  # The record names the boot image and the configuration it was made from by SHA-256,
  # and refuses a compiler line the container wrote with control bytes.
  def test_the_record_names_the_image_and_configuration
    Dir.mktmpdir do |out|
      File.write(File.join(out, 'image.elf'), 'ELF')
      File.write(File.join(out, 'compiler'), "genode-aarch64-gcc (GCC) 14.2.0\n")
      record = Erx::GenodeBuild.record(sources: [{ 'id' => 'genode', 'kind' => 'git', 'commit' => 'c' * 40 }],
                                       image: IMAGE, out: out, arguments: %w[posix 1])
      assert_equal Digest::SHA256.hexdigest('ELF'), record.fetch('image_sha256')
      assert_equal Digest::SHA256.hexdigest(Erx::GenodeBuild.run_script(arguments: %w[posix 1])), record.fetch('run_script_sha256')
      assert_equal 'genode-aarch64-gcc (GCC) 14.2.0', record.fetch('compiler')
      assert_equal({ 'genode' => 'c' * 40 }, record.fetch('sources'))
      File.write(File.join(out, 'compiler'), "gcc\e[31m\n")
      assert_raises(Erx::Error) { Erx::GenodeBuild.record(sources: [], image: IMAGE, out: out, arguments: []) }
    end
  end
end
