# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'etc'
require_relative 'error'
require_relative 'runner'
require_relative 'bounded_file'
require_relative 'generated'
require_relative 'native_root'

module Erx
  # erx-lvgl (docs/design-display.md, "The widget server"): LVGL from the git
  # submodule display/lvgl/lvgl (display/lvgl/ORIGIN.md), the generated ui.txt
  # reader and writer, and display/lvgl/erx_lvgl.c. Build makes it for the
  # host with display/lvgl/Makefile, into build/host/lvgl/VARIANT; the
  # sanitized variant, under ASan and UBSan, is the one the tests run. Program
  # makes it for the target. GNU make keeps the objects, so a rebuild compiles
  # only what changed. Nothing of the submodule runs: the build compiles its C
  # and nothing else.
  module Lvgl
    SUBMODULE = 'display/lvgl/lvgl'
    MAKEFILE = 'display/lvgl/Makefile'
    DEADLINE = 1800
    GIT_DEADLINE = 900
    STATUS_BYTES = 65_536
    HOST_FLAGS = '-g -O1'
    SANITIZE = '-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
    INIT_COMMAND = "git submodule update --init #{SUBMODULE}".freeze
    # The flags after S in the submodule field of a porcelain v2 entry.
    DRIFT_NOTES = { 'C' => 'is not at the commit the index records', 'M' => 'has changes to tracked files',
                    'U' => 'has untracked files' }.freeze

    module_function

    def checked_out?(root) = File.file?(File.join(root, SUBMODULE, 'lvgl.h'))

    # Clones the submodule at the commit the superproject records, with no
    # history, when it is not checked out yet; `git fetch --unshallow` in it
    # brings the history for patch work. A checkout that is there is left as
    # it is, so a patch being developed in it is never moved. `tools/erx
    # fetch` runs it: the one step that reaches the network for LVGL. Returns
    # the line that says which of the two it did.
    def init(root:, runner:)
      return "LVGL: #{SUBMODULE} is already checked out; left as it is" if checked_out?(root)
      git(root: root, runner: runner, name: 'lvgl-submodule-init',
          arguments: ['submodule', 'update', '--init', '--depth', '1', '--', SUBMODULE])
      "LVGL: cloned #{SUBMODULE} at the commit its gitlink records, without history"
    end

    # LVGL's tree for the build. A missing checkout is the one refusal. A
    # checkout that differs from what the superproject's HEAD records, or
    # that git cannot report on, is built with a warning, since a checkout
    # moved to a patch of the fork is how a patch is developed.
    def source_tree(root:, runner:)
      raise Error, "LVGL is not checked out at #{SUBMODULE}; run `#{INIT_COMMAND}`" unless checked_out?(root)
      notes = begin
        drift(status(root: root, runner: runner))
      rescue Error => error
        ["cannot be checked: #{error.message}"]
      end
      notes.each { |note| Terminal.puts("warning: #{SUBMODULE} #{note}") }
      File.join(root, SUBMODULE)
    end

    # Decides what `git status --porcelain=v2` says of the submodule. Its
    # entry, `1 XY S<c><m><u> mH mI mW hH hI path`, is absent when the
    # checkout and the index match HEAD. XY other than `..` is a change
    # staged or unstaged (a staged gitlink bump among them), hH and hI differ
    # when the index records another commit than HEAD, and c, m and u name
    # what differs in the checkout. An unmerged entry (`u`) is a conflict.
    def drift(porcelain)
      porcelain.each_line(chomp: true).flat_map do |line|
        kind, xy, sub, *rest = line.split(' ')
        next [] unless rest.last == SUBMODULE
        next ['has an unresolved merge conflict'] if kind == 'u'
        next [] unless %w[1 2].include?(kind) && sub&.start_with?('S')

        head, index = rest[3], rest[4]
        notes = DRIFT_NOTES.filter_map { |flag, note| note if sub.include?(flag) }
        notes.unshift('is staged at another commit than HEAD records') if head != index
        notes.empty? && xy != '..' ? ["differs from HEAD (#{xy})"] : notes
      end
    end

    # The submodule is never ignored and its untracked files are always
    # shown, whatever the user's configuration says; --no-optional-locks
    # keeps git from rewriting an index under the output limit.
    def status(root:, runner:)
      result = git(root: root, runner: runner, name: 'lvgl-submodule-status',
                   arguments: ['--no-optional-locks', 'status', '--porcelain=v2', '--ignore-submodules=none',
                               '--untracked-files=normal', '--', SUBMODULE],
                   output_limit: STATUS_BYTES)
      BoundedFile.read(result.fetch('log'), maximum: STATUS_BYTES)
    end

    # git on the superproject the root names, with no GIT_ variable of the
    # caller's environment and core.fsmonitor off, so it acts on that
    # checkout alone and starts no program its configuration names.
    def git(root:, runner:, name:, arguments:, output_limit: nil)
      unless File.exist?(File.join(root, '.git'))
        raise Error, "#{root} is not a git checkout, so git cannot fetch or check #{SUBMODULE}"
      end
      runner.run(['git', '-c', 'core.fsmonitor=false', '-C', root, *arguments], name: name,
                 deadline: GIT_DEADLINE, chdir: root, output_limit: output_limit,
                 env: ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] })
    rescue CommandError => error
      raise Error, "git #{arguments.grep_v(/\A-/).first} of #{SUBMODULE} failed; log: #{error.result.fetch('log')}"
    end
    private_class_method :status, :git

    # Builds the variant and returns the program's path.
    class Build
      def initialize(root:, runner:, sanitized: true, jobs: Etc.nprocessors)
        @root = File.expand_path(root)
        @runner = runner
        @sanitized = sanitized
        @jobs = jobs
      end

      def call
        tree = Lvgl.source_tree(root: @root, runner: @runner)
        Generated.ensure(root: @root)
        output = File.join(@root, 'build/host/lvgl', @sanitized ? 'sanitized' : 'plain')
        @runner.run(['gmake', "-j#{@jobs}", '-f', File.join(@root, MAKEFILE), "LVGL=#{tree}",
                     "GEN=#{File.join(@root, Generated::OUTPUT)}", "OUT=#{output}",
                     "CC=#{ENV.fetch('ERX_CLANG', 'clang')}", "FLAGS=#{HOST_FLAGS}", "SANITIZE=#{@sanitized ? SANITIZE : ''}"],
                    name: "lvgl-#{@sanitized ? 'sanitized' : 'plain'}", deadline: DEADLINE, chdir: @root)
        File.join(output, 'erx-lvgl')
      end
    end

    # erx-lvgl for the target, a native program of the session that runs it
    # (docs/design-programs.md, "Starting a program"). display/lvgl/Makefile compiles
    # LVGL into liblvgl.a with library_flags, the code generation of every task's C
    # (NativeRoot::CODE_FLAGS) and musl's headers, in a directory named by those flags, so
    # a change of them compiles LVGL again. NativeRoot then compiles erx_lvgl.c (with its
    # view of LVGL, NativeRoot::LVGL_FLAGS) and the generated ui.txt reader and writer
    # with the program flags, and links them, with the program's entry and liberx's
    # program layer, over liblvgl.a and the caller's archives at task.ld's addresses.
    # call returns NativeRoot#build_task_receipted's program, receipt and inputs, and the
    # archive: a release's packer attributes liblvgl.a whole, under LICENSE with NOTICES
    # (ProductionImage::Archive), and takes the rest as it does for any program.
    class Program
      NAME = 'erx-lvgl'
      SOURCES = %w[display/lvgl/erx_lvgl.c build/gen/display/generated/erx_ui_wire.c].freeze
      LIBRARY = 'build/lvgl/target'
      # What liblvgl.a holds under lv_conf.h: LVGL's own code, under MIT (LICENCE.txt),
      # and the one font LVGL's defaults turn on, Montserrat 14 (LV_FONT_MONTSERRAT_14
      # in include/lvgl/config/lv_conf_internal.h), in its two forms (src/font's
      # lv_font_montserrat_14.c and lv_font_montserrat_14_aligned.c, which is on unless
      # LV_FONT_MONTSERRAT_14_ALIGNED is 0). Their glyphs are generated from
      # Montserrat-Medium.ttf and Font Awesome 5's web font (each file's Opts line),
      # both under the SIL OFL 1.1: Montserrat's OFL.txt, and Font Awesome's LICENSE.txt,
      # whose OFL covers the icons it packages as web and desktop fonts. LVGL's
      # src/misc/lv_math.c holds Gaetan Renaudeau's cubic-bezier code under MIT, whose
      # notice is in that file alone, so the file is a notice. Every other third-party
      # library COPYRIGHTS.md lists is behind an LV_USE_ option that lv_conf.h or the
      # defaults leave at 0, and TLSF and printf behind LV_STDLIB_BUILTIN, which lv_conf.h
      # replaces with the C library's; FrogFS (MPL-2.0), whose decomp_raw.c no option
      # guards, the Makefile leaves out. These are the archive members that define a
      # symbol (llvm-nm --defined-only). A change to lv_conf.h that turns one of them on
      # changes this expression too (TODO.md).
      LICENSE = 'MIT AND OFL-1.1'
      NOTICES = %w[LICENCE.txt scripts/generators/built_in_font/font_license/Montserrat/OFL.txt
                   scripts/generators/built_in_font/font_license/FontAwesome5/LICENSE.txt src/misc/lv_math.c]
                .map { |notice| File.join(SUBMODULE, notice) }.freeze

      # LVGL's own compile flags, as one make word: the task code generation and musl's
      # headers, which hold what LVGL's LV_STDLIB_CLIB includes, with _BSD_SOURCE, since
      # -std=c17 hides the POSIX functions among them (strnlen), as NativeRoot's libc
      # sources have it.
      def self.library_flags(root) = [*NativeRoot::CODE_FLAGS, '-isystem', File.join(root, NativeRoot::LIBC_HEADERS), '-D_BSD_SOURCE'].join(' ')

      # Where LVGL compiled with flags is kept: a directory of LIBRARY named by their hash.
      def self.library_directory(root, flags) = File.join(root, LIBRARY, Digest::SHA256.hexdigest(flags)[0, 16])

      # archives are the libraries the program links over besides LVGL: musl's libc.a
      # and the compiler's runtime. generated makes build/gen, which holds the ui.txt
      # reader: Generated, or a test's stand-in.
      def initialize(root:, runner:, native:, compiler:, archives:, directory:, jobs: Etc.nprocessors, generated: Generated)
        @root = File.expand_path(root)
        @runner = runner
        @native = native
        @compiler = compiler
        @archives = archives
        @directory = directory
        @jobs = jobs
        @generated = generated
      end

      def call
        archive = make_library
        @native.build_task_receipted(name: NAME, sources: [*NativeRoot::PROGRAM, *SOURCES], directory: @directory,
                                     archives: [archive, *@archives])
               .merge(archive: archive).freeze
      end

      private

      # Runs display/lvgl/Makefile for liblvgl.a alone and returns its path.
      def make_library
        tree = Lvgl.source_tree(root: @root, runner: @runner)
        @generated.ensure(root: @root)
        flags = self.class.library_flags(@root)
        output = self.class.library_directory(@root, flags)
        archive = File.join(output, 'liblvgl.a')
        @runner.run(['gmake', "-j#{@jobs}", '-f', File.join(@root, MAKEFILE), "LVGL=#{tree}",
                     "GEN=#{File.join(@root, Generated::OUTPUT)}", "OUT=#{output}", "CC=#{@compiler}",
                     "AR=#{File.join(File.dirname(@compiler), 'llvm-ar')}", "FLAGS=#{flags}", 'SANITIZE=', archive],
                    name: 'lvgl-target', deadline: DEADLINE, chdir: @root)
        archive
      end
    end
  end
end
