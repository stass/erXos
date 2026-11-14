# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_jit_runtime'
require_relative '../../tools/lib/erx/runner'

# The runtime images' link lists (NativeRuntime::Built, NativeJitRuntime::Built): the
# system image's names its own static NIF table and nothing OpenSSL's or the NIFs' of
# DomainImageApps (docs/design-crypto.md, K1), and each domain image's names crypto's
# table. libbeam.a holds no table, so a list that named two tables, or none, fails the
# link: stand-ins of libbeam.a and the two tables, linked as NativeRoot#build links an
# image, with each fault seeded.
class NativeRuntimeLinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = '/otp/erts/emulator/obj/aarch64-unknown-erxos/opt'
  CRYPTO = Erx::NativeRuntime::Crypto.new(table: "#{OTP}/emu/driver_tab_crypto.o",
                                          nifs: Erx::DomainImageApps::NIF_ARCHIVES.map { |app, archive| "/otp/lib/#{app}/#{archive}" },
                                          libcrypto: '/openssl/prefix/lib/libcrypto.a')
  BUILT = Erx::NativeRuntime::Built.new(otp_archives: ["#{OTP}/emu/erl_main.o", '/otp/bin/libbeam.a'], libc: '/musl/libc.a',
                                        builtins: '/crt/libclang_rt.builtins.a', otp: '/otp', openssl: '/openssl/prefix',
                                        system_table: "#{OTP}/emu/driver_tab.o", crypto: CRYPTO)
  JIT = Erx::NativeJitRuntime::Built.new(otp_archives: ["#{OTP}/jit/erl_main.o", '/otp-jit/bin/libbeam.a'], libc: BUILT.libc,
                                         builtins: BUILT.builtins, otp: '/otp-jit', cxx_archives: ['/cxx/libc++.a'],
                                         crypto: CRYPTO.with(table: "#{OTP}/jit/driver_tab_crypto.o"))
  # The names OTP's make_driver_tab defines in each table, and libbeam.a's objects use.
  TABLE_NAMES = %w[driver_tab erts_static_nif_tab].freeze

  def test_the_system_link_names_its_own_table_and_no_openssl
    archives = BUILT.system_archives
    assert_equal 1, archives.count(BUILT.system_table)
    assert_empty archives & CRYPTO.archives
    refute archives.any? { |path| [Erx::Libcrypto::ARCHIVE, *Erx::DomainImageApps::NIF_ARCHIVES.values].include?(File.basename(path)) },
           "the system link takes OpenSSL or a NIF of DomainImageApps: #{archives}"
  end

  def test_each_domain_link_names_crypto_table_and_not_the_system_one
    [[BUILT, BUILT.domain_archives], [JIT, JIT.domain_archives]].each do |built, archives|
      assert_equal 1, archives.count(built.crypto.table)
      assert_empty built.crypto.archives - archives
      refute_includes archives, BUILT.system_table
    end
  end

  # The one-table rule holds only while OTP's make leaves the table out of libbeam.a: an
  # archived table would be taken silently by a list that named none.
  def test_libbeam_a_is_archived_without_the_table
    makefile = File.read(File.join(ROOT, 'otp/erts/emulator/Makefile.in'))
    rule = makefile[/^\$\(BINDIR\)\/\$\{EMULATOR_LIB\}:.*?\n\n/m]
    refute_nil rule, 'Makefile.in has no rule for libbeam.a'
    assert_includes rule, '$(filter-out $(OBJDIR)/driver_tab.o,$(OBJS))'
  end

  def test_the_system_list_links
    tools!
    link(stand_ins.system_archives)
  end

  def test_a_second_table_fails_the_link_on_a_duplicate
    tools!
    built = stand_ins
    error = assert_raises(Erx::Error) { link([*built.system_archives, built.crypto.table]) }
    assert_includes error.message, 'duplicate symbol: driver_tab'
  end

  def test_no_table_fails_the_link_on_an_undefined_symbol
    tools!
    built = stand_ins
    error = assert_raises(Erx::Error) { link(built.system_archives - [built.system_table]) }
    assert_includes error.message, 'undefined symbol: driver_tab'
  end

  def setup
    @compiler = ENV.fetch('ERX_CLANG', '')
    @linker = ENV.fetch('ERX_LLD', '')
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  private

  def tools!
    skip 'ERX_CLANG and ERX_LLD are not set: the link needs the LLVM clang, llvm-ar and ld.lld' if @compiler.empty? || @linker.empty?
    @directory = File.realpath(Dir.mktmpdir('erx-native-runtime-link-test-'))
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  # A Built of stand-ins: libbeam.a's, whose one member uses both table names as ERTS's
  # io.c and erl_nif.c do, the two tables', each defining both, and one archive of a
  # member no one uses for each other input.
  def stand_ins
    table = TABLE_NAMES.map { |name| "char #{name}[1];\n" }.join
    beam = compile('beam', "#{TABLE_NAMES.map { |name| "extern char #{name}[];\n" }.join}" \
                           "char *erl_start(int i) { return i ? driver_tab : erts_static_nif_tab; }\n")
    other = archive('other.a', compile('other', "int erx_link_test_other;\n"))
    crypto = CRYPTO.with(table: compile('driver_tab_crypto', table), nifs: [other], libcrypto: other)
    BUILT.with(otp_archives: [archive('libbeam.a', beam)], libc: other, builtins: other,
               system_table: compile('driver_tab', table), crypto: crypto)
  end

  def archive(name, member)
    path = File.join(@directory, name)
    @runner.run([File.join(File.dirname(@compiler), 'llvm-ar'), 'rcs', path, member], name: 'link-test-ar', deadline: 60)
    path
  end

  def compile(name, text)
    source = File.join(@directory, "#{name}.c")
    File.write(source, text)
    object = File.join(@directory, "#{name}.o")
    @runner.run([@compiler, '--target=aarch64-none-elf', '-std=c17', '-ffreestanding', '-c', source, '-o', object],
                name: "link-test-#{name}", deadline: 60)
    object
  end

  # The inputs in one group, as NativeRoot#build gives an image's archives to ld.lld; a
  # failed link raises with ld.lld's own output.
  def link(inputs)
    output = File.join(@directory, 'image')
    @runner.run([@linker, '-e', 'erl_start', '-o', output, '--start-group', *inputs, '--end-group'],
                name: 'link-test-link', deadline: 60)
  rescue Erx::CommandError => e
    raise Erx::Error, File.read(e.result.fetch('log'))
  end
end
