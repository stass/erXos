# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'error'
require_relative 'fiasco'
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
    # What the root's link takes: OTP's objects and archives, and musl's libc.a.
    Built = Data.define(:otp_archives, :libc, :otp)

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

    def initialize(root:, runner:, compiler:, linker:, fiasco:, oracle: Oracle.new(root: root, runner: runner))
      super(root: root, runner: runner, oracle: oracle)
      @compiler = compiler
      @linker = linker
      @fiasco = fiasco
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
      libc = build_sysroot(jobs: jobs)
      build_liberx
      copy_sources
      configure unless File.file?(in_copy('.erx-configured'))
      build_emulator(jobs: jobs)
      APPLICATIONS.each { |application| build_application(application, jobs: jobs) }
      build_erlang_apps
      check_imports
      File.write(self.class.record_path(@output), digest)
      Built.new(otp_archives: [File.join(@output.objects, 'erl_main.o'), File.join(File.dirname(@output.beam), 'libbeam.a'),
                       *RuntimeSeam.libraries(@output, target: TARGET)].freeze, libc: libc, otp: @output.root)
    end

    # Takes away everything build made, so the next build reruns musl's and OTP's own.
    def clean = FileUtils.rm_rf(@base)

    private

    # Builds musl and fills the sysroot with its headers and the libraries the link names; returns libc.a.
    def build_sysroot(jobs:)
      musl = Musl.new(root: @root, runner: @runner, compiler: @compiler)
      directory = File.join(@base, 'musl')
      libc = musl.build(directory: directory, jobs: jobs)
      merge_headers(musl.include_directories(directory: directory))
      lib = File.join(@sysroot, 'lib')
      FileUtils.mkdir_p(lib)
      FileUtils.cp(libc, lib)
      %w[libgcc.a libsigma0.a libl4sys.p.a].each { |name| FileUtils.cp(@fiasco.user_library(name), lib) }
      FileUtils.cp(@fiasco.boot_core_archive, File.join(lib, 'libboot_cores.a'))
      EMPTY_LIBRARIES.each { |name| archive(File.join(lib, "lib#{name}.a"), []) }
      libc
    end

    # configure looks for headers under one directory, so musl's search order, first one
    # winning, becomes one tree: the last layer copied is the first searched. Each copy
    # keeps its source's time, so a build that copies again leaves BeamAsm's precompiled
    # asmjit header, which clang judges by its headers' times, valid.
    def merge_headers(search_order)
      include_dir = File.join(@root, NativeRoot::LIBC_HEADERS)
      FileUtils.rm_rf(include_dir)
      search_order.reverse.each do |layer|
        Dir.glob('**/*.h', base: layer).each do |path|
          target = File.join(include_dir, path)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(File.join(layer, path), target, preserve: true)
        end
      end
    end

    def build_liberx
      root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: @fiasco)
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
                                             nm: File.join(@tools, 'llvm-nm'), cxx_runtime: cxx_runtime)
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
        # root.ld's place for ERTS's own links (otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf).
        'ERX_ROOT_PLACE_FLAGS' => NativeRoot.place_flags(NativeRoot::PLACE).map { |flag| "-Wl,#{flag}" }.join(' ')
      ).merge(flavour_environment).freeze
    end

    # The cross file's ERX_TARGET_FLAGS, the target and headers its CC and CXX compile
    # with, expanded as configure's shell expands them, so libc++ is built with the
    # compiler ERTS is. The value names only the two directories expanded here.
    def target_flags
      text = File.read(File.join(@root, 'otp', XCOMP_FILE))
      flags = text[/^ERX_TARGET_FLAGS="([^"]*)"$/, 1] or raise Error, "#{XCOMP_FILE} sets no ERX_TARGET_FLAGS"
      values = { 'ERX_SYSROOT' => @sysroot, 'ERX_CLANG_INCLUDE' => File.join(resource_directory, 'include') }
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
