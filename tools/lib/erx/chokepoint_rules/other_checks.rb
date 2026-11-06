# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # Rules other checks enforce, each with the test that seeds its violation.
    declare_group(
      rules: [
        Chokepoints::Elsewhere.new(
          name: 'core-archive-imports', rule: "the cores' archive leaves undefined only the erx_effect_* functions " \
                                               "and Fiasco's memcpy and memset",
          design: "#{STOPGAP}#interfaces", check: 'CoreArchive::UNDEFINED', test: 'test/host/core_archive_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'arch-terms', rule: "an architecture's terms appear only in its layer and its documents",
          design: "#{KERNEL}#chokepoint-checks", check: 'ArchTerms', test: 'test/host/arch_terms_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'generated-files', rule: 'generated files are never edited',
          design: "#{KERNEL}#chokepoint-checks", check: 'the generators\' --check drift runs',
          test: 'test/host/abi_generation_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'kernel-stack-proof', rule: 'kernel C recurses only through musttail, and every frame is proven',
          design: "#{KERNEL}#chokepoint-checks", check: 'StackProof', test: 'test/host/stack_proof_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'device-callers', rule: 'only erx_device and the driver applications name erx_device, whose NIF and BIFs ' \
                                        'reach a device',
          design: 'docs/design-runtime.md#the-device-nif', check: 'DeviceCallers, in Checks',
          test: 'test/host/device_callers_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'device-posters', rule: "only the block driver's one write path, erx_blk_write, calls erx_device:post/4, " \
                                        'and it builds every request it posts',
          design: 'docs/design-storage.md#data-model', check: 'DevicePosters, in Checks',
          test: 'test/host/device_posters_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'erofs-reads', rule: 'the EROFS reader reaches an image only through erx_verity:read/3, and only erx_verity ' \
                                     'reaches the window behind it',
          design: 'docs/design-storage.md#reading-erofs-images', check: 'ErofsReads, in Checks',
          test: 'test/host/erofs_reads_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'test-image-builder', rule: "only the oracle's QEMU run and the block device suite's harness call the " \
                                            "production image's test entry point, and no other tools source passes a " \
                                            "literal true for the packer's test keyword",
          design: "#{STOPGAP}#the-production-image", check: 'Checks::TEST_IMAGE_BUILDERS',
          test: 'test/host/checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'json-input', rule: 'host tooling parses JSON only through JsonInput',
          design: 'docs/design-build.md', check: 'Checks::JSON_OUTSIDE_WRITING', test: 'test/host/checks_test.rb'
        )
      ]
    )
  end
end
