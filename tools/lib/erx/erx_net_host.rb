# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'error'

module Erx
  # erx_net laid out for a run on the development host's stock OTP, as a user's build
  # lays it out (docs/design-network-stack.md, "Two places, four seams"): its modules go
  # to erx_net/ebin under a work directory, and c_src/Makefile builds its native parts
  # into erx_net/priv beside it, where code:priv_dir(erx_net) finds them. The portable
  # erx_bytes loads priv/erx_bytes_nif.so and fails to load without it, so every host
  # run of the stack builds the library; tap: true adds the tap helper erx_net_tap.
  module ErxNetHost
    ROOT = File.expand_path('../../..', __dir__)
    C_SRC = File.join(ROOT, 'erlang/apps/erx_net/c_src')

    # c_src/Makefile failed; the message is make's output.
    class BuildError < Erx::Error; end

    module_function

    # Creates work/erx_net/ebin and builds the native parts into work/erx_net/priv with
    # the host's C compiler, warnings as errors, against the headers of erl, the emulator
    # that will load the library. c_src names another copy of c_src/, such as one with a
    # seeded fault. Returns the ebin directory.
    def lay_out(work, erl:, tap: false, c_src: C_SRC)
      ebin = File.join(work, 'erx_net', 'ebin')
      FileUtils.mkdir_p(ebin)
      build(File.join(work, 'erx_net', 'priv'), erl: erl, targets: tap ? %w[nif tap] : %w[nif], c_src: c_src)
      ebin
    end

    def build(priv, erl:, targets:, c_src:)
      output, status = Open3.capture2e('make', '-C', c_src, "PRIV=#{priv}", "ERL=#{erl}", 'CFLAGS=-Werror',
                                       *targets, stdin_data: '')
      raise BuildError, output unless status.success?
    end
    private_class_method :build
  end
end
