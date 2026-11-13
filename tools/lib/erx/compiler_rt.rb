# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'build_memo'
require_relative 'dependencies'
require_relative 'error'
require_relative 'native_root'

module Erx
  # The compiler's helper routines every erXos target link takes last: LLVM
  # compiler-rt's builtins, compiled from the pinned llvm-project source with erXos's
  # own clang and task flags into one static archive, in place of GCC's libgcc
  # (docs/design.md, "Dependencies"). compiler-rt's own CMake is not run: the build
  # compiles the files SOURCES names, which are data read from the fetched tree.
  #
  # SOURCES is two closed families and the cache flush, not the symbols one link
  # happens to need today, so a new use of long double or __int128 links without a
  # change here, and a helper outside them fails its link by name:
  # * binary128 (long double) arithmetic, comparison and conversion, which musl's
  #   long double and printf reach: compiler-rt's GENERIC_TF_SOURCES, less the two
  #   half-precision conversions, since nothing erXos builds has _Float16;
  # * 128-bit integer arithmetic, shifts, counts and conversions (the ti helpers),
  #   less the overflow-trapping v forms, which abort through a libc and nothing
  #   erXos builds asks for (-ftrapv);
  # * __clear_cache, which BeamAsm calls after writing code, and the FPCR and FPSR
  #   reads behind the binary128 helpers' rounding mode and inexact flag.
  # Outline atomics (lse.S) are left out: every task compiles -mno-outline-atomics.
  class CompilerRt
    SOURCE_ID = 'llvm-project'
    BUILTINS = 'compiler-rt/lib/builtins'
    # The license text the archive's attribution carries, in the fetched tree.
    NOTICE = 'compiler-rt/LICENSE.TXT'
    LICENSE = 'Apache-2.0 WITH LLVM-exception'
    ARCHIVE = 'libclang_rt.builtins.a'
    BINARY128 = %w[
      addtf3 comparetf2 divtc3 divtf3 extenddftf2 extendsftf2 fixtfdi fixtfsi fixtfti
      fixunstfdi fixunstfsi fixunstfti floatditf floatsitf floattitf floatunditf
      floatunsitf floatuntitf multc3 multf3 powitf2 subtf3 trunctfdf2 trunctfsf2
    ].freeze
    INTEGER128 = %w[
      ashlti3 ashrti3 clzti2 cmpti2 ctzti2 divmodti4 divti3 ffsti2 fixdfti fixsfti
      fixunsdfti fixunssfti floattidf floattisf floatuntidf floatuntisf lshrti3 modti3
      muloti4 multi3 negti2 parityti2 popcountti2 ucmpti2 udivmodti4 udivti3 umodti3
    ].freeze
    SOURCES = [*BINARY128, *INTEGER128, 'clear_cache', 'aarch64/fp_mode'].map { |name| "#{name}.c" }.freeze
    # The tasks' code generation, and compiler-rt's own: no builtin may be compiled
    # into a call to itself, and the helpers stay out of a program's exported names.
    FLAGS = [*NativeRoot::CODE_FLAGS, *%w[-fno-builtin -fvisibility=hidden -DVISIBILITY_HIDDEN
                                          -ffunction-sections -fdata-sections]].freeze

    # The archive, built from the pinned source unless the one last built came from the
    # same compiler, flags and source bytes: what every link site passes.
    def self.archive(root:, runner:, compiler:) = new(root: root, runner: runner, compiler: compiler).build

    # The archive's attribution: its license and the path of its notice, relative to root.
    def self.notice(root:, runner:)
      tree = Dependencies.new(root: root, runner: runner).fetched_tree(SOURCE_ID)
      File.join(tree, NOTICE).delete_prefix("#{File.expand_path(root)}/")
    end

    def initialize(root:, runner:, compiler:, base: File.join(root, 'build/compiler-rt'))
      raise Error, 'set ERX_CLANG to the installed LLVM clang' if compiler.to_s.empty?

      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @base = base
    end

    # Compiles every source in one clang run, each object named for its source, and
    # archives them deterministically. A stamp holds the inputs' key, so a build with
    # the same compiler, archiver, flags and bytes leaves the archive as it is. The
    # objects and the archive are made in a directory of this build's own and the
    # archive renamed into place, so two builds of one tree never mix their objects.
    def build
      builtins = File.join(Dependencies.new(root: @root, runner: @runner).fetched_tree(SOURCE_ID), BUILTINS)
      archive = File.join(@base, ARCHIVE)
      stamp = File.join(@base, 'key')
      compile = [@compiler, *FLAGS, '-I', builtins, '-c', *SOURCES.map { |name| File.join(builtins, name) }]
      inputs = inputs_key(compile, builtins)
      return archive if File.file?(archive) && File.file?(stamp) && File.read(stamp) == inputs

      FileUtils.mkdir_p(@base)
      Dir.mktmpdir('.build-', @base) do |objects|
        @runner.run(compile, name: 'compiler-rt-builtins', deadline: 300, chdir: objects)
        members = SOURCES.map { |name| File.join(objects, "#{File.basename(name, '.c')}.o") }
        built = File.join(objects, ARCHIVE)
        @runner.run([archiver, 'rcsD', built, *members], name: 'compiler-rt-archive', deadline: 60, chdir: @root)
        File.rename(built, archive)
      end
      File.write(stamp, inputs)
      archive
    end

    private

    def archiver = File.join(File.dirname(@compiler), 'llvm-ar')

    # What the archive's bytes follow from: the compile command, the compiler and the
    # archiver, and every source, header and included body (.inc) the compile can read.
    def inputs_key(compile, builtins)
      read = [*SOURCES, *Dir.glob('**/*.{h,inc}', base: builtins).sort]
      JSON.generate('compile' => compile, 'compiler' => BuildMemo.program_identity(@compiler),
                    'archiver' => BuildMemo.program_identity(archiver),
                    'inputs' => read.to_h { |name| [name, Digest::SHA256.file(File.join(builtins, name)).hexdigest] })
    end
  end
end
