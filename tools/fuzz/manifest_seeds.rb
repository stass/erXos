# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/manifest_context'
require_relative '../lib/erx/abi'
require_relative '../lib/erx/json_input'
require_relative '../lib/erx/manifest'

module Erx
  # The seeds of the targets that read a system manifest: the bytes the packer writes.
  # QEMU virt's development manifest, as Phase 1's check admits it for a production image,
  # and the empty native manifest of the structural test images, with prefixes of the first.
  module ManifestSeeds
    module_function

    def all
      repository = File.expand_path('../..', __dir__)
      codec = ABI::Codec.new(ABI::Generator.plan(root: repository).schema)
      fixture = ManifestContextFixture.arguments(codec)
      platform = JsonInput.parse(File.binread(File.join(repository, 'config/platforms/qemu-virt.json')),
                                 max_bytes: 65_536, label: 'config/platforms/qemu-virt.json')
      development = Manifest.admit(source: File.binread(File.join(repository, 'config/manifest/qemu-virt-development.txt')),
                                   codec: codec, context: Manifest::Context.new(**fixture, platform: platform))
      empty = Manifest.structural_fixture(source: File.binread(File.join(repository, 'test/fixtures/manifest_empty.txt')),
                                          codec: codec, context: Manifest::Context.new(**fixture))
      PackFuzz.prefix_seeds(development.bytes).merge('empty' => empty.bytes)
    end
  end
end
