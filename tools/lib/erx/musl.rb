# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'error'

module Erx
  # erXos's musl, built out of its tree by its own Makefile for the erxos arch.
  # The arch's seam calls liberx's fiasco backend, whose objects the program links.
  class Musl
    ARCH = 'erxos'
    CPU = 'aarch64'
    # What musl's configure would choose for this compiler, and the target a root task links for.
    CFLAGS = %w[--target=aarch64-none-elf -Os -pipe -fomit-frame-pointer -fno-unwind-tables
                -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections -frounding-math
                -fno-stack-protector -mno-outline-atomics -Wa,--noexecstack].freeze

    # The CPU's sources under source that trap to a kernel with no replacement under
    # the arch: a build holding one would reach the kernel past liberx.
    def self.unreplaced_traps(source)
      Dir[File.join(source, 'src/*', CPU, '*')].sort.select do |path|
        stem = File.basename(path, '.*')
        File.binread(path).match?(/\bsvc\b/n) && Dir[File.join(File.dirname(path), '..', ARCH, "#{stem}.*")].empty?
      end
    end

    def initialize(root:, runner:, compiler:)
      raise Error, 'set ERX_CLANG to the installed LLVM clang' if compiler.to_s.empty?

      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
    end

    # Builds lib/libc.a under directory and returns its path. Make decides what is stale.
    def build(directory:, jobs: 4)
      traps = Musl.unreplaced_traps(source)
      raise Error, "musl sources trap past liberx: #{traps.join(', ')}" unless traps.empty?

      FileUtils.mkdir_p(directory)
      bin = File.dirname(@compiler)
      arguments = ['-f', File.join(source, 'Makefile'), "-j#{jobs}", "srcdir=#{source}", "ARCH=#{ARCH}", "CC=#{@compiler}",
                   "CFLAGS_AUTO=#{CFLAGS.join(' ')}", "AR=#{bin}/llvm-ar", "RANLIB=#{bin}/llvm-ranlib", "ERX_ROOT=#{@root}",
                   "ERX_COMPILER_INCLUDE=#{compiler_include}", 'lib/libc.a']
      @runner.run(['gmake', *arguments], name: 'musl-build', deadline: 900, chdir: directory)
      File.join(directory, 'lib/libc.a')
    end

    # In search order, for a program compiled with -nostdinc against this musl.
    def include_directories(directory:)
      [File.join(directory, 'obj/include'), File.join(source, 'arch', ARCH), File.join(source, 'arch', CPU),
       File.join(source, 'arch/generic'), File.join(source, 'include')]
    end

    private

    def source = File.join(@root, 'musl')

    def compiler_include
      output, status = Open3.capture2(@compiler, '-print-resource-dir')
      raise Error, "#{@compiler} did not print its resource directory" unless status.success?

      File.join(output.strip, 'include')
    rescue SystemCallError => e
      raise Error, "#{@compiler} did not run: #{e.message}"
    end
  end
end
