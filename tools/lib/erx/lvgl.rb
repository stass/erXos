# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'etc'
require_relative 'error'
require_relative 'runner'
require_relative 'dependencies'
require_relative 'generated'

module Erx
  # erx-lvgl for the host (docs/design-display.md, "The widget server"):
  # LVGL from deps.lock's pin, the generated ui.txt reader and writer, and
  # display/lvgl/erx_lvgl.c, built by display/lvgl/Makefile into
  # build/host/lvgl/VARIANT. The sanitized variant, under ASan and UBSan, is
  # the one the tests run; make keeps the objects, so a rebuild compiles only
  # what changed.
  module Lvgl
    SOURCE_ID = 'lvgl'
    MAKEFILE = 'display/lvgl/Makefile'
    DEADLINE = 1800
    SANITIZE = '-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'

    # Builds the variant and returns the program's path.
    class Build
      def initialize(root:, runner:, sanitized: true, jobs: Etc.nprocessors)
        @root = File.expand_path(root)
        @runner = runner
        @sanitized = sanitized
        @jobs = jobs
      end

      def call
        Generated.ensure(root: @root)
        output = File.join(@root, 'build/host/lvgl', @sanitized ? 'sanitized' : 'plain')
        @runner.run(['make', "-j#{@jobs}", '-f', File.join(@root, MAKEFILE),
                     "LVGL=#{Dependencies.new(root: @root, runner: @runner).fetched_tree(SOURCE_ID)}",
                     "GEN=#{File.join(@root, Generated::OUTPUT)}", "OUT=#{output}",
                     "CC=#{ENV.fetch('ERX_CLANG', 'clang')}", "SANITIZE=#{@sanitized ? SANITIZE : ''}"],
                    name: "lvgl-#{@sanitized ? 'sanitized' : 'plain'}", deadline: DEADLINE, chdir: @root)
        File.join(output, 'erx-lvgl')
      end
    end
  end
end
