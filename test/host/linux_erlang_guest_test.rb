# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/linux_erlang_guest'

# Linux's Erlang guest (docs/design-bench.md, "Linux's Erlang guest"): where the oracle's
# install export lands in the initramfs and which members may run, the interpreter its
# programs name, and the host's refusal
# of a boot whose identity line is not stock OTP 29.1.2 in the expected flavour.
class LinuxErlangGuestTest < Minitest::Test
  ERTS = 'install/lib/erlang/erts-17.1.1/bin'
  LOADER = '/lib/ld-linux-aarch64.so.1'

  # A 64-bit little-endian ELF file whose one program header is a PT_INTERP naming name.
  def elf(name, type: 3, offset: 120)
    path = "#{name}\0".b
    header = "\x7fELF\x02\x01".b.ljust(32, "\0") + [64].pack('Q<') + ("\0" * 14) + [56, 1].pack('S<S<') + ("\0" * 6)
    header + [type, 0, offset, 0, 0, path.bytesize, path.bytesize, 1].pack('L<L<Q<Q<Q<Q<Q<Q<') + path
  end

  def export_files(loader: LOADER)
    Erx::OracleExport::INSTALL_PROGRAMS.map { |program| ["#{ERTS}/#{program}", elf(loader)] } +
      ["#{ERTS}/escript", 'install/lib/erlang/lib/kernel-11.0/ebin/kernel.app', "libraries#{LOADER}",
       'libraries/usr/lib/aarch64-linux-gnu/libcrypto.so.3'].map { |path| [path, path.b] }
  end

  def archived(files)
    Erx::LinuxErlangGuest.entries(files: files, init: 'init'.b, beams: { 'erx_bench_hist' => 'beam'.b }).to_h do |entry|
      [entry.path, entry]
    end
  end

  # The tree keeps its installed prefix, each library its loader's path, and only /init,
  # the five programs of the ERTS directory and the interpreter they name may run.
  def test_the_tree_keeps_its_prefix_and_only_init_the_programs_and_their_interpreter_run
    entries = archived(export_files)
    runnable = entries.values.select { |entry| entry.type == :file && entry.mode.anybits?(0o111) }.map(&:path)
    assert_equal ['init', LOADER.delete_prefix('/'),
                  *Erx::OracleExport::INSTALL_PROGRAMS.map { |program| "tmp/erx-oracle/#{ERTS}/#{program}" }].sort,
                 runnable.sort
    assert_equal 'install/lib/erlang/lib/kernel-11.0/ebin/kernel.app'.b,
                 entries.fetch('tmp/erx-oracle/install/lib/erlang/lib/kernel-11.0/ebin/kernel.app').data
    assert entries.key?('lib/ld-linux-aarch64.so.1')
    assert entries.key?('usr/lib/aarch64-linux-gnu/libcrypto.so.3')
    assert_equal "127.0.0.1\tlocalhost\n", entries.fetch('etc/hosts').data
    assert entries.key?('bench/ebin/erx_bench_hist.beam')
    assert_equal :character, entries.fetch('dev/console').type
    assert_equal :character, entries.fetch('dev/null').type
    assert(%w[proc sys tmp usr usr/lib].all? { |path| entries.fetch(path).type == :directory })
    # The archive's own checks hold: each directory precedes what it holds.
    refute_empty Erx::NewcArchive.write(Erx::LinuxErlangGuest.entries(files: export_files, init: 'i'.b, beams: {}))
  end

  # An export member outside the tree and the libraries, or one whose name escapes the
  # root, never reaches the archive.
  def test_an_export_path_outside_its_roots_is_refused
    assert_raises(Erx::Error) { archived([['evidence/result.json', ''.b]]) }
    assert_raises(Erx::Error) { archived([['libraries/../etc/passwd', ''.b]]) }
  end

  # The interpreter the programs name must arrive with them, and a program whose program
  # headers do not name one interpreter inside the file, in its shape, is refused.
  def test_the_programs_interpreter_is_read_from_their_headers_and_must_be_packed
    assert_match(/holds no lib\/ld-musl-aarch64\.so\.1/,
                 assert_raises(Erx::Error) { archived(export_files(loader: '/lib/ld-musl-aarch64.so.1')) }.message)
    guest = Erx::LinuxErlangGuest
    assert_equal LOADER, guest.interpreter(elf(LOADER))
    assert_nil guest.interpreter(elf(LOADER, type: 1))
    two = elf(LOADER).tap { |data| data[56, 2] = [2].pack('S<') }
    [elf(LOADER)[0, 63], 'MZ'.b.ljust(200, "\0"), two, elf(LOADER, offset: 1 << 40), elf('lib/relative'),
     elf("/lib/\e]0;x")].each do |data|
      assert_raises(Erx::Error) { guest.interpreter(data) }
    end
  end

  def test_the_bindir_is_the_exports_one_erts_directory
    inventory = { 'files' => export_files.map { |path, _| { 'path' => path } } }
    assert_equal "/tmp/erx-oracle/#{ERTS}", Erx::LinuxErlangGuest.bindir(inventory)
    inventory['files'] << { 'path' => 'install/lib/erlang/erts-17.2/bin/erlexec' }
    assert_raises(Erx::Error) { Erx::LinuxErlangGuest.bindir(inventory) }
    # A directory whose name is not erts-VERSION never reaches the launcher's build.
    inventory = { 'files' => [{ 'path' => 'install/lib/erlang/erts-1"x/bin/erlexec' }] }
    assert_raises(Erx::Error) { Erx::LinuxErlangGuest.bindir(inventory) }
  end

  def test_only_stock_29_1_2_in_the_expected_flavour_is_accepted
    assert_nil Erx::LinuxErlangGuest.identity_refusal("boot\r\nERX_ORACLE 29.1.2 jit\r\nBENCH x\r\n")
    assert_equal "the guest's OTP is 28.0.1 jit, not 29.1.2 jit",
                 Erx::LinuxErlangGuest.identity_refusal("ERX_ORACLE 28.0.1 jit\n")
    assert_equal "the guest's OTP is 29.1.2 emu, not 29.1.2 jit",
                 Erx::LinuxErlangGuest.identity_refusal("ERX_ORACLE 29.1.2 emu\n")
    assert_equal 'the guest printed 0 ERX_ORACLE lines', Erx::LinuxErlangGuest.identity_refusal("BENCH x\n")
    assert_equal 'the guest printed 2 ERX_ORACLE lines',
                 Erx::LinuxErlangGuest.identity_refusal("ERX_ORACLE 29.1.2 jit\nERX_ORACLE 29.1.2 jit\n")
    # Guest text that is not the line's shape is never repeated.
    assert_equal "the guest's ERX_ORACLE line is malformed",
                 Erx::LinuxErlangGuest.identity_refusal("ERX_ORACLE 29.1.2 jit\e]0;x\a\n")
  end

  # A start boot as systools writes it: release vsn, and one {path, Dirs} instruction.
  def boot(dirs, vsn: '29')
    etf = Erx::Etf
    atom = ->(name) { etf::Atom.new(name: name) }
    tuple = ->(*elements) { etf::Tuple.new(elements: elements) }
    etf.encode(tuple.call(atom.call('script'), tuple.call('Erlang/OTP'.bytes, vsn.bytes),
                          [tuple.call(atom.call('progress'), atom.call('preloaded')),
                           tuple.call(atom.call('path'), dirs.map(&:bytes))]))
  end

  def inventory(paths) = paths.map { |path| { 'path' => path } }

  # Only what the two nodes load is packed: the ERTS directory's five programs, the start
  # boot, its release's OTP_VERSION, the code path the boot sets and the libraries; the
  # other programs, the applications the boot does not name and the sources stay out.
  def test_only_the_boot_its_code_path_and_the_programs_are_packed
    root = 'install/lib/erlang'
    kept = [*Erx::OracleExport::INSTALL_PROGRAMS.map { |program| "#{ERTS}/#{program}" }, "#{root}/bin/no_dot_erlang.boot",
            "#{root}/releases/29/OTP_VERSION", "#{root}/lib/kernel-11.0.4/ebin/kernel.app",
            "#{root}/lib/stdlib-8.1.1/ebin/lists.beam", "libraries#{LOADER}"]
    left = ["#{ERTS}/escript", "#{root}/bin/start.boot", "#{root}/releases/29/start.script",
            "#{root}/lib/kernel-11.0.4/src/code.erl", "#{root}/lib/kernel-11.0.4/include/file.hrl",
            "#{root}/lib/crypto-6.0/ebin/crypto.beam", "#{root}/lib/kernel-11.0.40/ebin/x.beam",
            "#{root}/usr/include/erl_nif.h"]
    start = boot(['$ROOT/lib/kernel-11.0.4/ebin', '$ROOT/lib/stdlib-8.1.1/ebin'])
    packed = Erx::LinuxErlangGuest.packed(inventory(kept + left), boot: start).map { |file| file.fetch('path') }
    assert_equal kept.sort, packed.sort
  end

  # A boot the export lacks, or one that names what the tree cannot hold, refuses the build.
  def test_a_boot_that_cannot_be_packed_is_refused
    guest = Erx::LinuxErlangGuest
    files = inventory(['install/lib/erlang/bin/no_dot_erlang.boot', 'install/lib/erlang/releases/29/OTP_VERSION'])
    assert_match(/OTP_VERSION/, assert_raises(Erx::Error) { guest.packed(files, boot: boot([], vsn: '30')) }.message)
    assert_match(/no_dot_erlang\.boot/, assert_raises(Erx::Error) { guest.packed(files.drop(1), boot: boot([])) }.message)
    ['/usr/lib/erlang/ebin', '$ROOT/../x', '$ROOT/lib/./x', "$ROOT/lib/\e]0;x"].each do |dir|
      assert_raises(Erx::Error) { guest.packed(files, boot: boot([dir])) }
    end
    [boot(['$ROOT/lib']).dup.tap { |data| data[1] = "\x00" }, Erx::Etf.encode(Erx::Etf::Atom.new(name: 'script'))].each do |data|
      assert_raises(Erx::Error) { guest.packed(files, boot: data) }
    end
  end

  # The seeded /init gives the echo node another cookie: the fault is caught only when the
  # cross cell failed while the same-node cell was measured.
  def test_the_seeded_boot_is_caught_only_by_a_failed_cross_cell_beside_a_measured_local_one
    cell = Struct.new(:operation, :status)
    caught = lambda do |local, cross|
      Erx::LinuxErlangGuest.seed_caught?([cell.new('local-rtt', local), cell.new('xdomain-pingpong', cross)])
    end
    assert caught.call('measured', 'failed')
    refute caught.call('measured', 'measured')
    refute caught.call('failed', 'failed')
    refute caught.call('measured', 'timed_out')
    refute Erx::LinuxErlangGuest.seed_caught?([cell.new('local-rtt', 'measured')])
  end

  # Without the install export the landing reports its cell not run, naming the command
  # that makes the export, and boots nothing.
  def test_the_landing_without_an_export_is_not_run
    refusing = Struct.new(:refused) do
      def refusal(_profile) = refused
      def call(*) = raise('booted without an export')
    end.new("linux's Erlang guest needs the oracle's install export: run `x`")
    landing = Erx::LinuxErlangGuest::Landing.new(root: '/nonexistent', runner: nil, guest: refusing)
    assert_equal({ not_run: refusing.refused },
                 landing.call(Erx::BenchSuite.benchmark('xdomain'), boot: Erx::BenchSuite::LINUX_ERLANG,
                                                                    history: '/nonexistent'))
  end

  # The client's argument reaches it through the kernel's command line, which splits on
  # spaces and treats double quotes as its own.
  def test_the_clients_argument_is_one_command_line_word
    benchmark = Erx::BenchSuite.benchmark('xdomain')
    guests = Erx::LinuxErlangGuest.guests(Erx::LinuxErlangGuest.asked(benchmark))
    assert_match(/\A\[\{erx_xdomain_bench,.*echo=>\{erx_xdomain_echo,'bench_echo@127\.0\.0\.1'\}/, guests)
    refute_match(/[\s"]/, guests)
    assert_equal 'monotonic', Erx::LinuxErlangGuest.asked(benchmark).clock
  end
end
