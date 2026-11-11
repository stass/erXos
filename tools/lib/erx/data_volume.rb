# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'medium_image'
require_relative 'output_directory'
require_relative 'pack_tools'

module Erx
  # The data partition's littlefs volume as installation writes it (docs/design-storage.md,
  # "A mount never formats"): the only place a volume is made. The guest never formats, so a medium
  # whose data partition holds no volume fails its mount, and the storage domain with it.
  #
  # The host program lfs-format (tools/host/lfs_format.c, built by PackTools from the
  # in-tree littlefs the guest's NIF builds, with the guest's geometry) formats a volume
  # of the partition's length and writes its leading blocks; the rest of a fresh volume
  # is the zeros every medium writer leaves. A medium writer places those blocks at the
  # partition's start with `pieces`.
  module DataVolume
    NAME = 'data.lfs'
    TOOL_DIRECTORY = 'lfs-format-tool'

    module_function

    # Formats the volume of a data partition of data_sectors sectors as NAME in
    # directory, which the caller owns under owner_root, building lfs-format from root's
    # sources beside it; returns the volume's leading blocks as a MediumImage::FilePiece.
    # An existing NAME is refused.
    def format(root:, runner:, directory:, data_sectors:, owner_root: root, compiler: ENV.fetch('ERX_CLANG', 'clang'))
      raise Error, 'the data partition length is not a positive sector count' unless data_sectors.is_a?(Integer) && data_sectors.positive?

      tool = PackTools.build(root: root, owner_root: owner_root, directory: File.join(directory, TOOL_DIRECTORY), runner: runner,
                             compiler: compiler, tools: ['formatter']).fetch('formatter')
      path = File.join(directory, NAME)
      tool.run([data_sectors.to_s, path], runner: runner, name: 'lfs-format', deadline: 60)
      MediumImage::FilePiece.new(path: path, length: File.size(path))
    end

    # The medium's pieces that hold volume, which format returned: its blocks from the
    # data partition's first sector.
    def pieces(volume) = { MediumImage.constant('data_start') => volume }
  end
end
