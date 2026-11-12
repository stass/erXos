# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # A shipped file never names the directory its tree was built in: that would carry
  # the build host's paths onto the medium and make its bytes depend on where the tree
  # was checked out. The target's compiles map the tree's path away, in __FILE__ and in
  # debug information (ERX_TARGET_FLAGS in otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf),
  # and erlc is given paths relative to the tree. The image's writer
  # (ProductionImage#assemble) and the card's (BootPartition.write) check what they ship
  # with find_in. It reads the bytes as they are: a path inside compressed data, such as
  # a beam's literal or debug chunk, is not seen.
  module BuildPath
    # The spellings of root a file could hold: as given, and with its symbolic links
    # resolved, since a compiler or a tool may name it either way.
    def self.spellings(root) = [File.expand_path(root), File.realpath(root)].uniq

    # The spelling of root that bytes holds as a directory, a path under it, or nil when
    # it holds none. The spelling must start a path, not end a longer name, so a tree at
    # a short path such as /src does not match kernel/src/.
    def self.find_in(bytes, root:)
      binary = bytes.b
      spellings(root).find { |path| binary.match?(pattern(path)) }
    end

    def self.pattern(path) = Regexp.new("(?<![A-Za-z0-9_.-])#{Regexp.escape(path)}/".b, Regexp::NOENCODING)
    private_class_method :pattern
  end
end
