# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'fiasco'
require_relative 'libcrypto'
require_relative 'musl'
require_relative 'native_root'
require_relative 'runtime'
require_relative 'runtime_seam'

module Erx
  # ERTS's interpreter for the native root, by OTP's own configure and make in a private
  # copy, as the hosted runtime is. Its compiler sees erXos's musl alone, through a sysroot
  # of musl's headers and the libraries the root's link names. OTP's own link of beam.emu
  # checks that no name is missing; the root the image boots is linked again by NativeRoot,
  # from the same objects, for its link map.
  class NativeRuntime < Runtime
    TARGET = 'aarch64-unknown-erxos'
    XCOMP_FILE = "xcomp/erl-xcomp-#{TARGET}.conf".freeze
    # configure and ERTS ask for these libraries by name, and musl keeps them all in libc.a.
    EMPTY_LIBRARIES = %w[m pthread rt dl util].freeze
    # What the root's link takes: OTP's objects and archives, musl's libc.a, and
    # compiler-rt's builtins (CompilerRt). openssl is the directory OTP's configure built
    # crypto's NIF against (build_openssl), which the BeamAsm build's configure is pointed
    # at too. crypto_archives are what a domain's interpreter image links beyond the system
    # image's (docs/design-crypto.md, "Three runtime images"): the static NIF table that
    # names crypto and asn1rt_nif, the two NIFs' archives, and OpenSSL's libcrypto.a.
    Built = Data.define(:otp_archives, :libc, :builtins, :otp, :openssl, :crypto_archives) do
      # The interpreter image's link, in link order. The table comes first: its symbols are
      # then defined before libbeam.a is read, so libbeam.a's own driver_tab.o, the system
      # image's table, is never taken, and a table that missed one of its symbols would
      # make the link fail on a duplicate rather than mix the two.
      def domain_archives = [*crypto_archives, *otp_archives, libc, builtins]
    end

    # Each static NIF archive a domain's image links, by the OTP application that builds it.
    NIF_ARCHIVES = { 'asn1' => 'asn1rt_nif.a', 'crypto' => 'crypto.a' }.freeze

    BASE = 'build/runtime/native'
    # The musl sysroot, which the BeamAsm build (NativeJitRuntime) shares.
    SYSROOT = "#{BASE}/sysroot".freeze

    def self.output(root:) = flavour_output(root: root, base: BASE, flavour: FLAVOR)

    # The build of one flavour under base: OTP's copy, its emulator and objects.
    def self.flavour_output(root:, base:, flavour:)
      otp = File.join(root, base, 'otp')
      Output.new(root: otp, beam: File.join(otp, 'bin', TARGET, "beam.#{flavour}"),
                 objects: File.join(otp, 'erts/emulator/obj', TARGET, 'opt', flavour),
                 liberx: File.join(root, SYSROOT, 'lib/liberxroot.a'), archive: nil)
    end

    def initialize(root:, runner:, compiler:, linker:, fiasco:, platform:, oracle: Oracle.new(root: root, runner: runner))
      super(root: root, runner: runner, oracle: oracle)
      @compiler = compiler
      @linker = linker
      @fiasco = fiasco
      raise Error, "a runtime is linked for a Platform" unless platform.is_a?(Platform)

      @platform = platform
      @base = File.join(@root, self.class::BASE)
      @sysroot = File.join(@root, SYSROOT)
      @tools = File.dirname(compiler)
      OutputDirectory.check(root: @root, path: @base)
    end

    # Make decides what is stale, so a build after no change costs seconds. Fiasco's build
    # must have run.
    def build(jobs: 4)
      @oracle.verify(HOST_OTP_FLAVOUR)
      FileUtils.rm_f(self.class.record_path(@output))
      # Also brings build/gen up to date, which the steps below read.
      digest = self.class.source_digest(root: @root, generated: @generated)
      libc, builtins = build_sysroot(jobs: jobs)
      @openssl = build_openssl(jobs: jobs)
      build_liberx
      copy_sources
      configure unless File.file?(in_copy('.erx-configured'))
      build_emulator(jobs: jobs)
      crypto_archives = build_crypto_nifs(jobs: jobs)
      APPLICATIONS.each { |application| build_application(application, jobs: jobs) }
      build_erlang_apps
      check_imports
      File.write(self.class.record_path(@output), digest)
      Built.new(otp_archives: [File.join(@output.objects, 'erl_main.o'), File.join(File.dirname(@output.beam), 'libbeam.a'),
                       *RuntimeSeam.libraries(@output, target: TARGET)].freeze, libc: libc, builtins: builtins,
                otp: @output.root, openssl: @openssl, crypto_archives: crypto_archives)
    end

    # Takes away everything build made, so the next build reruns musl's and OTP's own.
    def clean = FileUtils.rm_rf(@base)

    private

    # Builds musl and compiler-rt's builtins and fills the sysroot with musl's headers and the
    # libraries the link names; returns libc.a and the builtins archive.
    def build_sysroot(jobs:)
      musl = Musl.new(root: @root, runner: @runner, compiler: @compiler)
      directory = File.join(@base, 'musl')
      libc = musl.build(directory: directory, jobs: jobs)
      musl.merge_headers(directory: directory, into: File.join(@root, NativeRoot::LIBC_HEADERS))
      lib = File.join(@sysroot, 'lib')
      FileUtils.mkdir_p(lib)
      FileUtils.cp(libc, lib)
      builtins = CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler)
      FileUtils.cp(builtins, lib)
      %w[libsigma0.a libl4sys.p.a].each { |name| FileUtils.cp(@fiasco.user_library(name), lib) }
      FileUtils.cp(@fiasco.boot_core_archive, File.join(lib, 'libboot_cores.a'))
      EMPTY_LIBRARIES.each { |name| archive(File.join(lib, "lib#{name}.a"), []) }
      [libc, builtins]
    end

    # OpenSSL's libcrypto.a, built against this build's musl (Libcrypto), and the directory
    # OTP's configure is pointed at with --with-ssl (ERX_OPENSSL): OpenSSL's headers with
    # those its Configure generates, as one include/, and lib/libcrypto.a, the layout
    # configure looks for. rsync and a preserving copy keep unchanged files' times, so
    # make rebuilds no crypto object for a build that changed nothing. Returns the directory.
    def build_openssl(jobs:)
      directory = File.join(@base, 'openssl')
      archive = Libcrypto.new(root: @root, runner: @runner, compiler: @compiler)
                         .build(directory: File.join(directory, 'obj'), sysroot: @sysroot, jobs: jobs)
      prefix = File.join(directory, 'prefix')
      FileUtils.mkdir_p(File.join(prefix, 'lib'))
      [File.join(@root, 'openssl/include/'), File.join(directory, 'obj/include/')].each do |headers|
        @runner.run(['rsync', '-a', headers, File.join(prefix, 'include/')], name: 'native-runtime-openssl-headers',
                                                                           deadline: DEADLINES.fetch(:copy))
      end
      FileUtils.cp(archive, File.join(prefix, 'lib', Libcrypto::ARCHIVE), preserve: true)
      prefix
    end

    # OTP's asn1rt_nif and crypto NIFs as static archives, by each application's own
    # static_lib target, and the emulator's static NIF table that names them
    # (erts/emulator/Makefile.in, erx_crypto_tab). Returns crypto_archives (Built).
    def build_crypto_nifs(jobs:)
      %w[asn1 crypto].each do |application|
        @runner.run(['gmake', "-j#{jobs}", '-C', "lib/#{application}", 'static_lib', 'BUILD_STATIC_LIBS=1',
                     "TARGET=#{TARGET}"],
                    name: "runtime-#{application}-nif", deadline: DEADLINES.fetch(:libs), chdir: @output.root,
                    env: build_environment)
      end
      # The configured makefile itself: erts/emulator/Makefile forwards only OTP's own targets.
      @runner.run(['gmake', '-C', 'erts/emulator', '-f', "#{TARGET}/Makefile", 'erx_crypto_tab', 'TYPE=opt',
                   "FLAVOR=#{self.class::FLAVOR}", "TARGET=#{TARGET}"],
                  name: 'runtime-crypto-tab', deadline: DEADLINES.fetch(:emulator), chdir: @output.root,
                  env: build_environment)
      [File.join(@output.objects, 'driver_tab_crypto.o'), *nif_archives, File.join(@openssl, 'lib', Libcrypto::ARCHIVE)].freeze
    end

    # The two NIF archives build_crypto_nifs makes, which check_imports counts as inside.
    def nif_archives = NIF_ARCHIVES.map { |application, archive| in_copy(File.join('lib', application, 'priv/lib', TARGET, archive)) }

    def build_liberx
      root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform,
                                 fiasco: @fiasco)
      archive(@output.liberx, root_task.compile_all(sources: NativeRoot::SYSTEM, directory: File.join(@base, 'liberx')))
    end

    def archive(path, members)
      FileUtils.rm_f(path)
      @runner.run([File.join(@tools, 'llvm-ar'), 'rcs', path, *members], name: 'native-runtime-archive',
                                                                          deadline: DEADLINES.fetch(:compile), chdir: @root)
    end

    def check_imports = check_imports_of(cxx_runtime: [])

    # The sections that name what only the other backend's C library makes of the calls
    # stay out: make check-runtime-seam reads the same file for the hosted build.
    # cxx_runtime are the C++ runtime's archives the BeamAsm image links, whose names
    # its objects may use.
    def check_imports_of(cxx_runtime:)
      report = RuntimeSeam.check_elf_objects(objects: RuntimeSeam.objects(@output, target: TARGET),
                                             imports_text: File.read(in_copy(RuntimeSeam::IMPORTS_FILE)),
                                             nm: File.join(@tools, 'llvm-nm'), cxx_runtime: cxx_runtime,
                                             nifs: nif_archives)
      warn("listed and imported by nothing on the native build: #{report.unused.join(' ')}") unless report.unused.empty?
      return if report.violations.empty?

      names = report.violations.map(&:name).uniq.sort
      raise Error, "ERTS's objects import names #{RuntimeSeam::IMPORTS_FILE} does not list: #{names.join(' ')}"
    end

    def build_environment
      Oracle::CLEAN_ERLANG_ENV.merge(
        'ERL_TOP' => @output.root,
        # The release's beams, the same bytes as the hosted build's.
        'ERL_COMPILE_FLAGS' => '+deterministic',
        'PATH' => [File.dirname(@oracle.erl_path(HOST_OTP_FLAVOUR)), ENV.fetch('PATH')].join(File::PATH_SEPARATOR),
        'ERX_CLANG' => @compiler,
        'ERX_CLANG_INCLUDE' => File.join(resource_directory, 'include'),
        'ERX_LLD' => @linker,
        'ERX_LLVM_BIN' => @tools,
        'ERX_SYSROOT' => @sysroot,
        'ERX_TREE' => @root,
        'ERX_GEN' => File.join(@root, Generated::OUTPUT),
        'ERX_OPENSSL' => @openssl,
        # root.ld's place for ERTS's own links (otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf).
        'ERX_ROOT_PLACE_FLAGS' => NativeRoot.place_flags(NativeRoot.development_place(@platform), ram_first: @platform.ram_first).map { |flag| "-Wl,#{flag}" }.join(' ')
      ).merge(flavour_environment).freeze
    end

    # The cross file's ERX_TARGET_FLAGS, the target, headers and source names its CC and
    # CXX compile with, expanded as configure's shell expands them, so libc++ is built with the
    # compiler ERTS is. The value names only the three directories expanded here.
    def target_flags
      text = File.read(File.join(@root, 'otp', XCOMP_FILE))
      flags = text[/^ERX_TARGET_FLAGS="([^"]*)"$/, 1] or raise Error, "#{XCOMP_FILE} sets no ERX_TARGET_FLAGS"
      values = { 'ERX_SYSROOT' => @sysroot, 'ERX_CLANG_INCLUDE' => File.join(resource_directory, 'include'), 'ERX_TREE' => @root }
      flags.gsub(/\$([A-Z_]+)/) do
        name = Regexp.last_match(1)
        values.fetch(name) { raise Error, "ERX_TARGET_FLAGS in #{XCOMP_FILE} names $#{name}, which the build does not expand" }
      end.split
    end

    # The cross file's flavour switches: the interpreter's configure disables the JIT
    # and its links take no C++ runtime.
    def flavour_environment = { 'ERX_JIT' => '--disable-jit', 'ERX_CXX_INCLUDE' => '', 'ERX_CXX_LIBS' => '' }

    def resource_directory
      @resource_directory ||= begin
        output, status = Open3.capture2(@compiler, '-print-resource-dir', in: File::NULL)
        raise Error, "#{@compiler} does not name its resource directory" unless status.success?

        output.strip
      end
    end

    # The configure stamp records the sysroot where the hosted build records its SDK.
    def sdk_root = @sysroot
  end
end
