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
          name: 'generated-files', rule: 'generated files are never checked in or edited',
          design: "#{KERNEL}#chokepoint-checks",
          check: 'Erx::Generated.ensure (refuses a tree file at a generated path; regenerates over an edited output)',
          test: 'test/host/generated_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'kernel-stack-proof', rule: 'kernel C recurses only through musttail, and every frame is proven',
          design: "#{KERNEL}#chokepoint-checks", check: 'StackProof', test: 'test/host/stack_proof_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'device-callers', rule: 'only erx_device, erx_irq_line and the driver applications name erx_device, whose NIF and BIFs ' \
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
          name: 'net-atoms', rule: 'no module of erx_net names binary_to_atom, list_to_atom or binary_to_term',
          design: 'docs/design-network-stack.md#build-checks', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'net-payload-copy', rule: 'the modules a TCP payload passes through copy one only at the sites the fast ' \
                                          "path's design lists",
          design: 'docs/design-network-fastpath.md#copies', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'net-seq-wrap', rule: 'among the TCP modules of erx_net, only erx_tcp_seq does sequence-space wrap arithmetic',
          design: 'docs/design-network-stack.md#build-checks', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'net-notices', rule: "the FreeBSD files the header of a module of erx_net names are those NOTICE-freebsd " \
                                     'lists for it, and the reverse',
          design: 'docs/design-network-stack.md#provenance-and-notices', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'net-grant-key', rule: "in erx_net_client, only erx_inet reads the application's grant key, so every " \
                                       'answer of the grant passes erx_sock_admit through erx_inet:call/1',
          design: 'docs/design-network-stack.md#build-checks', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'net-call-timeout', rule: 'in erx_net and erx_net_client, every gen_server, gen_statem and gen call ' \
                                          'waits with the literal infinity',
          design: 'docs/design-network-stack.md#build-checks', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'net-origin', rule: 'in erx_net and erx_net_client, only erx_net_admit and erx_sock_admit name erx_origin, ' \
                                    'the envelope of a message from another domain',
          design: 'docs/design-network-stack.md#build-checks', check: 'NetChecks, in Checks',
          test: 'test/host/net_checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'command-needs', rule: "only a command that declares a service's facet with -erx_needs names a module " \
                                       'of that service of the system domain, and no other module of erx_shell names one',
          design: 'docs/design-shell.md#invariants', check: 'CommandNeeds, in Checks',
          test: 'test/host/command_needs_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'facet-names', rule: 'a domain reaches another domain only through a facet the table of abi/services ' \
                                     'and the system manifest declares, each interface citing its design section',
          design: 'docs/design-abi.md#services-facets-and-their-parameter-schemas', check: 'FacetNames, in Checks',
          test: 'test/host/facet_names_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'json-input', rule: 'host tooling parses JSON only through JsonInput',
          design: 'docs/design-build.md', check: 'Checks::JSON_OUTSIDE_WRITING', test: 'test/host/checks_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'counter-reads', rule: "only erx_fiasco_counter reads the timer's counter in a linked program, " \
                                       'and the read sits between two ISBs',
          design: 'docs/design-arch-aarch64.md#timer', check: 'CounterReads, on every NativeRoot link',
          test: 'test/host/counter_reads_test.rb'
        )
      ]
    )
  end
end
