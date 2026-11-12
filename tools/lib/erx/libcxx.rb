# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'dependencies'
require_relative 'error'

module Erx
  # BeamAsm's C++ runtime: LLVM's libc++ and libc++abi, static, without exceptions, RTTI
  # or localisation, built out of tree from the pinned llvm-project source for the
  # target ERTS's native build compiles for, over erXos's musl (docs/design-runtime.md,
  # "BeamAsm"). Only the BeamAsm image links them; the interpreter image's build check
  # refuses any of their names. Threads come from musl's pthreads, so a static
  # initialisation guard that waits waits on a musl condition variable, which is an umtx
  # wait.
  class Libcxx
    SOURCE_ID = 'llvm-project'
    # What the build installs: the headers a C++ compile puts first in its search order,
    # and the two archives a link takes; and the configuration they were built with,
    # which a build compiling against the headers records, since its make does not
    # track system headers.
    Built = Data.define(:include, :archives, :configuration)
    # The runtimes' cache entries. Each property the design names is one switch here:
    # no exceptions in either library, no RTTI, no localisation. The rest fit a static
    # runtime that BeamAsm alone uses on a target with no file system, no entropy device
    # and no shared objects: no filesystem library, random device or time-zone database,
    # no LLVM unwinder (nothing unwinds), musl's pthreads as the thread API, and no tests.
    OPTIONS = {
      'LLVM_ENABLE_RUNTIMES' => 'libcxx;libcxxabi',
      'CMAKE_BUILD_TYPE' => 'Release',
      'LIBCXX_ENABLE_EXCEPTIONS' => 'OFF',
      'LIBCXXABI_ENABLE_EXCEPTIONS' => 'OFF',
      'LIBCXX_ENABLE_RTTI' => 'OFF',
      'LIBCXX_ENABLE_LOCALIZATION' => 'OFF',
      'LIBCXX_ENABLE_SHARED' => 'OFF',
      'LIBCXXABI_ENABLE_SHARED' => 'OFF',
      'LIBCXX_ENABLE_STATIC' => 'ON',
      'LIBCXXABI_ENABLE_STATIC' => 'ON',
      'LIBCXX_ENABLE_FILESYSTEM' => 'OFF',
      'LIBCXX_ENABLE_RANDOM_DEVICE' => 'OFF',
      'LIBCXX_ENABLE_TIME_ZONE_DATABASE' => 'OFF',
      'LIBCXX_ENABLE_STATIC_ABI_LIBRARY' => 'OFF',
      'LIBCXX_CXX_ABI' => 'libcxxabi',
      'LIBCXXABI_USE_LLVM_UNWINDER' => 'OFF',
      'LIBCXX_HAS_MUSL_LIBC' => 'ON',
      'LIBCXX_HAS_PTHREAD_API' => 'ON',
      'LIBCXXABI_HAS_PTHREAD_API' => 'ON',
      # musl's libc.a holds pthreads and clocks: no library of their own is named in the
      # archives' dependent-library notes, which a link with no such library refuses.
      'LIBCXX_HAS_PTHREAD_LIB' => 'OFF',
      'LIBCXX_HAS_RT_LIB' => 'OFF',
      'LIBCXXABI_HAS_PTHREAD_LIB' => 'OFF',
      'LIBCXX_INSTALL_MODULES' => 'OFF',
      'LIBCXX_INCLUDE_TESTS' => 'OFF',
      'LIBCXXABI_INCLUDE_TESTS' => 'OFF',
      'LIBCXX_INCLUDE_BENCHMARKS' => 'OFF',
      'LIBCXX_INCLUDE_DOCS' => 'OFF',
      # A cross build for a target with no CMake platform file: its compiler checks make
      # archives, since nothing links a program before ERTS's own link.
      'CMAKE_SYSTEM_NAME' => 'Generic',
      'CMAKE_SYSTEM_PROCESSOR' => 'aarch64',
      'CMAKE_TRY_COMPILE_TARGET_TYPE' => 'STATIC_LIBRARY'
    }.freeze
    ARCHIVES = %w[libc++.a libc++abi.a].freeze
    DEADLINES = { configure: 600, build: 1_800 }.freeze

    # The cache entries for a build with compiler (clang, under any name, beside clang++, llvm-ar and
    # llvm-ranlib), whose C and C++ see exactly target_flags' headers, installing into
    # install.
    def self.cache_arguments(compiler:, target_flags:, install:)
      tools = File.dirname(compiler)
      flags = target_flags.join(' ')
      OPTIONS.merge(
        'CMAKE_C_COMPILER' => compiler, 'CMAKE_CXX_COMPILER' => File.join(tools, 'clang++'),
        'CMAKE_AR' => File.join(tools, 'llvm-ar'), 'CMAKE_RANLIB' => File.join(tools, 'llvm-ranlib'),
        'CMAKE_C_FLAGS' => flags, 'CMAKE_CXX_FLAGS' => flags, 'CMAKE_INSTALL_PREFIX' => install
      ).map { |name, value| "-D#{name}=#{value}" }
    end

    # target_flags are the C compiler's target, header and source-name flags of ERTS's
    # native build (NativeJitRuntime), so libc++ is compiled against the musl ERTS is and
    # names its sources as ERTS does.
    def initialize(root:, runner:, compiler:, target_flags:, base: File.join(root, 'build/runtime/libcxx'))
      raise Error, 'set ERX_CLANG to the installed LLVM clang' if compiler.to_s.empty?

      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @target_flags = target_flags
      @base = base
    end

    # Configures a build tree once for each configuration, since CMake's cache keeps an
    # entry a later configure no longer names: a change to the source or to an argument
    # starts from an empty tree. ninja then decides what is stale, and installs.
    def build(jobs: 4)
      source = File.join(Dependencies.new(root: @root, runner: @runner).fetched_tree(SOURCE_ID), 'runtimes')
      tree = File.join(@base, 'build')
      install = File.join(@base, 'install')
      configure = ['cmake', '-G', 'Ninja', '-S', source, '-B', tree,
                   *self.class.cache_arguments(compiler: @compiler, target_flags: @target_flags, install: install)]
      stamp = File.join(@base, 'configured')
      unless File.file?(stamp) && File.read(stamp) == configure.join("\n")
        FileUtils.rm_rf([tree, install, stamp])
        FileUtils.mkdir_p(tree)
        @runner.run(configure, name: 'libcxx-configure', deadline: DEADLINES.fetch(:configure), chdir: @root)
        File.write(stamp, configure.join("\n"))
      end
      @runner.run(['ninja', '-C', tree, "-j#{jobs}", 'install-cxx', 'install-cxxabi'], name: 'libcxx-build',
                                                                                    deadline: DEADLINES.fetch(:build), chdir: @root)
      built(install, configuration: configure.join("\n"))
    end

    def clean = FileUtils.rm_rf(@base)

    private

    def built(install, configuration:)
      archives = ARCHIVES.map { |name| File.join(install, 'lib', name) }
      include = File.join(install, 'include/c++/v1')
      missing = [*archives, include].reject { |path| File.exist?(path) }
      raise Error, "the libc++ build left no #{missing.join(', ')}" unless missing.empty?

      Built.new(include: include, archives: archives.freeze, configuration: configuration)
    end
  end
end
