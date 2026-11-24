# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz helper

require_relative '../lib/erx/app_package'

module Erx
  # App package files for erx_pkg_header's tests and fuzz target, their headers written by
  # the packer's encoder (Erx::AppPackage.header). The decoder reads only a file's length
  # and its first pkg_header_max bytes, so a sample is those two; the image and the hash
  # tree are zeros, which nothing before a mount reads, and the salt and root hash are fixed
  # bytes, which the decoder does not check, as are the key and signature unless the caller
  # names a signer that seals the header (erx_pkg's tests). Edits replace fields of
  # the header's fixed part after the layout is computed, so a sample can be wrong in
  # exactly one field.
  module PackageSeeds
    Sample = Data.define(:name, :length, :prefix)
    # A signer of fixed bytes.
    Signer = Data.define(:public_key, :signature) do
      def sign(_bytes) = signature
    end

    ARCH = AppPackage.architecture
    SIGNER = Signer.new(public_key: "\x11".b * 32, signature: "\x22".b * 64)
    SALT = "\x5a".b * 32
    ROOT_HASH = "\xa5".b * 32
    ERLANG = AppPackage::Declaration.new(name: 'dashboard', needs: %w[display data], gatt: %w[nus],
                                         start: AppPackage::Applications.new(names: %w[erx_dashboard erx_charts]),
                                         license: 'BSD-2-Clause', memory: 67_108_864, version: 3)
    NATIVE = AppPackage::Declaration.new(name: 'doom', needs: %w[display], gatt: [],
                                         start: AppPackage::Program.new(path: 'bin/doom',
                                                                        args: ['-iwad', '', '/app/share/freedoom1.wad']),
                                         license: '', memory: 134_217_728, version: 1)

    module_function

    def codec = AppPackage.codec
    def block = AppPackage.block
    def header_max = codec.constant('pkg_header_max')

    # The sample of a well-formed package, or of one whose header fields edits replace,
    # whose header bytes header_edit rewrites, whose length length_edit changes or whose
    # first bytes prefix_edit rewrites.
    def sample(name, declaration:, image_blocks:, tree_blocks:, signer: SIGNER, edits: ->(values) { values },
               header_edit: ->(bytes) { bytes }, length_edit: ->(length) { length },
               prefix_edit: ->(bytes) { bytes })
      header = header_edit.call(header(declaration, image_blocks: image_blocks, tree_blocks: tree_blocks,
                                                    signer: signer, edits: edits))
      boundary = ((header.bytesize + block - 1) / block) * block
      length = length_edit.call(boundary + ((image_blocks + tree_blocks) * block))
      file_start = header + ("\0".b * (boundary - header.bytesize))
      prefix = file_start.byteslice(0, [length, header_max].min).ljust([length, header_max].min, "\0")
      Sample.new(name: name, length: length, prefix: prefix_edit.call(prefix.b).b.freeze)
    end

    def header(declaration, image_blocks:, tree_blocks:, signer: SIGNER, edits: ->(values) { values })
      AppPackage.header(declaration, image_blocks: image_blocks, tree_blocks: tree_blocks,
                                     salt: SALT, root_hash: ROOT_HASH, signer: signer, &edits)
    end
  end
end
