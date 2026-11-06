# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'

module Erx
  # The chokepoint "only the block driver's one write path issues writes"
  # (docs/design-storage.md, "The block driver", and invariant U4). A virtio block
  # device writes the medium only for a request whose header says VIRTIO_BLK_T_OUT, and
  # Erlang has that value only by the generated name ERX_VIRTIO_BLK_T_OUT
  # (erlang/apps/erx/include/generated/erx_abi.hrl, from abi/formats/virtio.txt). The rule
  # is therefore that no Erlang source but erx_blk_write, the write path, and the generated
  # header that defines the name names it.
  #
  # The check reads the Erlang sources that can enter a release, as DeviceCallers does,
  # with comments removed and strings kept, so a quoted name is refused too. Like it, it
  # catches a slip, not a determined bypass that writes the number 1 into a header; what
  # holds the rule against that is review of the driver's few modules, which DeviceCallers
  # keeps the only ones that reach the device.
  module BlockWritePath
    NAME = 'ERX_VIRTIO_BLK_T_OUT'
    SITES = %w[erlang/apps/erx_blk/src/erx_blk_write.erl erlang/apps/erx/include/generated/erx_abi.hrl].freeze
    NAMED = /(?<![A-Za-z0-9_@])#{NAME}(?![A-Za-z0-9_@])/

    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint block-write-path: #{path}:#{line}: only #{SITES.first} may name #{NAME}"
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] if !covers?(path) || SITES.include?(path)

        DeviceCallers.code(text).each_line.with_index(1).filter_map do |line, number|
          Violation.new(path: path, line: number) if NAMED.match?(line)
        end
      end
    end
  end
end
