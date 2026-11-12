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
  # the same with configured domains (ManifestContextFixture.domain_source), the empty
  # native manifest of the structural test images, with prefixes of the first, the
  # configured domains' with its first row's boot_timeout_s 0, which the reader refuses,
  # the configured domains' with alpha's log granted to the system principal's
  # session template, so the facet table holds a session grantee, and the same with a
  # start row for that template, left off and with its own restart intensity.
  module ManifestSeeds
    SESSION_FACET = "facet session_log\n  grantee @session.system\n  service @service.log\n  operations none\n" \
                    "  max_request 64\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    START_ROW = "start system\n  enable NO\n  restarts 3\n  restart_period_s 60\n"

    module_function

    def all
      repository = File.expand_path('../..', __dir__)
      codec = ABI::Codec.new(ABI::Generator.plan(root: repository).schema)
      fixture = ManifestContextFixture.arguments(codec)
      platform = JsonInput.parse(File.binread(File.join(repository, 'config/platforms/qemu-virt.json')),
                                 max_bytes: 65_536, label: 'config/platforms/qemu-virt.json')
      source = File.binread(File.join(repository, 'config/manifest/qemu-virt-development.txt'))
      context = Manifest::Context.new(**fixture, platform: platform)
      development = Manifest.admit(source: source, codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
      # A terminal escape in an argument, which the boot page's reader refuses.
      escape = Manifest.admit(source: source.sub(/^\s*system_args .*$/, '  system_args hex:2d5a1b5d323b7265766965770700'),
                              codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
      empty = Manifest.structural_fixture(source: File.binread(File.join(repository, 'test/fixtures/manifest_empty.txt')),
                                          codec: codec, context: Manifest::Context.new(**fixture))
      domain_context = Manifest::Context.new(**ManifestContextFixture.domain_arguments(codec), platform: platform)
      domains = Manifest.admit(source: ManifestContextFixture.domain_source(source), codec: codec,
                               context: domain_context, planner: ManifestContextFixture.accepting_planner)
      session = Manifest.admit(source: ManifestContextFixture.domain_source(source) + SESSION_FACET, codec: codec,
                               context: domain_context, planner: ManifestContextFixture.accepting_planner)
      start = Manifest.admit(source: ManifestContextFixture.domain_source(source) + SESSION_FACET + START_ROW, codec: codec,
                             context: domain_context, planner: ManifestContextFixture.accepting_planner)
      PackFuzz.prefix_seeds(development.bytes).merge('empty' => empty.bytes, 'system-args-escape' => escape.bytes,
                                                     'domains' => domains.bytes, 'session-grantee' => session.bytes,
                                                     'start-row' => start.bytes,
                                                     'boot-timeout-zero' => boot_timeout(codec, domains.bytes, 0))
    end

    # The manifest bytes with their first configured domain's boot_timeout_s set to seconds.
    def boot_timeout(codec, bytes, seconds)
      offset = codec.open('manifest', bytes).header.fetch('domains').fetch('offset')
      row = codec.decode_layout('erx_mf_domain', bytes, offset: offset, prefix: true)
      encoded = codec.encode_layout('erx_mf_domain', row.merge('boot_timeout_s' => seconds))
      bytes.b.tap { |copy| copy[offset, encoded.bytesize] = encoded }
    end
  end
end
