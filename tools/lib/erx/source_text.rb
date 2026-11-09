# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module SourceText
    SUFFIXES = %w[.c .h .cc .cpp .hpp .s .S .erl .hrl .rb .ld .lds .mk .sh
                  .lua .pl .pm .ac .am .m4 .tla .cfg .svd .ts .tsx].freeze
    SCRIPT_NAMES = %w[configure otp_build otp_patch_apply].freeze
    module_function

    def source?(path, bytes:)
      return false if File.extname(path) == '.md'
      SUFFIXES.include?(File.extname(path)) || SCRIPT_NAMES.include?(File.basename(path)) ||
        File.basename(path).match?(/\A(?:GNUmakefile|Makefile|makefile)(?:\..*)?\z/) ||
        path.split('/').include?('include') || path.start_with?('abi/', 'hw/') ||
        bytes.start_with?('#!')
    end
  end
end
