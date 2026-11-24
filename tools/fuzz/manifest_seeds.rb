# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz helper

require_relative '../lib/erx/display_domain'
require_relative '../lib/erx/platform'
require_relative '../../test/fixtures/manifest_context'
require_relative '../lib/erx/abi'
require_relative '../lib/erx/manifest'

module Erx
  # The seeds of the targets that read a system manifest: the bytes the packer writes.
  # QEMU virt's development manifest, as the manifest check accepts it for a production image,
  # the same with configured domains (ManifestContextFixture.domain_source), the empty
  # native manifest of the structural test images, with prefixes of the first, the
  # configured domains' with the machine's boot_timeout_s 0, which the reader refuses,
  # the configured domains' with alpha's probe granted to the system principal's
  # session template, so the facet table holds a session grantee, and the same with a
  # start row for that template, left off and with its own restart intensity, and the
  # display_domain suite's manifest with its client's grant of the display stating each
  # parameter of the windows interface a facet row may, so the facet table holds parameter
  # rows, the configured domains' with alpha granted the line on a UART of its own, so a
  # parameter row holds a device reference, the development manifest with its inspect grant
  # naming both operations, so the facet table holds operation rows, the configured
  # domains' with alpha granted the ble service beta serves, so a parameter span holds an
  # identifier set, and the configured domains' with an apps row
  # offering one service, two packages, a signer and the build's development key, so each
  # of those tables holds rows.
  module ManifestSeeds
    SESSION_FACET = "facet session_probe\n  grantee @session.system\n  service @service.probe\n  operations none\n" \
                    "  max_request 64\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    START_ROW = "start system\n  enable NO\n  restarts 3\n  restart_period_s 60\n"
    # The service named packages_service and a service of the net interface, appnet, which
    # the apps row offers, so the build derives the app template's packages row and a row
    # of appnet.
    PACKAGE_ROWS = "service packages\n  server @domain.beta\n  interface files\n" \
                   "service appnet\n  server @domain.alpha\n  interface net\n" \
                   "apps\n  memory 1048576\n  max 2\n  services appnet\npackage clock\n  input @artifact.package-clock\n  enable YES\n" \
                   "package quotes\n  input @artifact.package-quotes\nsigner ops\n  key hex:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd\n"
    WINDOWS_PARAMETERS = "  parameter pixels 4194304\n  parameter windows 2\n  parameter clipboard yes\n"
    # The operations operations_grant's grant of inspect names.
    INSPECT_OPERATIONS = 'entries,inspect'
    # The net grant's parameters: sockets, ports a full set of 16, stated out of order, and
    # listen one of them, so its rows are a scalar, two sets, and a set at its most.
    NET_PORTS = (2000...2016).to_a.freeze
    NET_PARAMETERS = "  parameter sockets 80\n#{NET_PORTS.reverse.map { |port| "  parameter ports #{port}\n" }.join}" \
                     "  parameter listen #{NET_PORTS.last}\n".freeze
    # The services ble_grant's grant names, out of byte order, which the packer sorts:
    # nus before nusb, its extension, and nusb before nv.
    BLE_SERVICES = %w[nv nusb nus].freeze
    # The UART line_grant's grant names.
    LINE_UART = ManifestContextFixture::LINE_UARTS.fetch('line_a').first

    module_function

    def all
      repository = File.expand_path('../..', __dir__)
      codec = ABI::Codec.new(ABI::Generator.plan(root: repository).schema)
      fixture = ManifestContextFixture.arguments(codec)
      platform = platform_of(repository, 'qemu-virt')
      source = Platform.load(root: repository, name: 'qemu-virt').manifest_source(repository)
      context = Manifest::Context.new(**fixture, platform: platform)
      development = Manifest.admit(source: source, codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
      # A terminal escape in an argument, which the boot page's reader refuses.
      escape = Manifest.admit(source: source.sub(/^\s*system_args .*$/, '  system_args hex:2d5a1b5d323b7265766965770700'),
                              codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
      pi = Manifest.admit(source: Platform.load(root: repository, name: 'raspi4b').manifest_source(repository),
                          codec: codec, context: Manifest::Context.new(**fixture, platform: platform_of(repository, 'raspi4b')),
                          planner: ManifestContextFixture.accepting_planner)
      empty = Manifest.admit(source: File.binread(File.join(repository, 'test/fixtures/manifest_empty.txt')),
                             codec: codec, context: Manifest::Context.new(**fixture))
      domain_context = Manifest::Context.new(**ManifestContextFixture.arguments(codec), platform: platform)
      domains = Manifest.admit(source: ManifestContextFixture.domain_source(source), codec: codec,
                               context: domain_context, planner: ManifestContextFixture.accepting_planner)
      session = Manifest.admit(source: ManifestContextFixture.domain_source(source) + SESSION_FACET, codec: codec,
                               context: domain_context, planner: ManifestContextFixture.accepting_planner)
      start = Manifest.admit(source: ManifestContextFixture.domain_source(source) + SESSION_FACET + START_ROW, codec: codec,
                             context: domain_context, planner: ManifestContextFixture.accepting_planner)
      PackFuzz.prefix_seeds(development.bytes).merge('empty' => empty.bytes, 'system-args-escape' => escape.bytes,
                                                     'windows-grant' => windows_grant(repository, codec),
                                                     'line-grant' => line_grant(repository, codec),
                                                     'ble-grant' => ble_grant(source, codec, platform),
                                                     'operations-grant' => operations_grant(source, codec, platform),
                                                     'net-grant' => net_grant(repository, codec),
                                                     'domains' => domains.bytes, 'session-grantee' => session.bytes,
                                                     'start-row' => start.bytes, 'raspi4b' => pi.bytes,
                                                     'packages' => packages(source, codec, platform),
                                                     'boot-timeout-zero' => boot_timeout(codec, domains.bytes, 0))
    end

    # The display_domain suite's manifest, its client's grant stating WINDOWS_PARAMETERS, as
    # the check packs it over the fixture's archive with a planner that places nothing.
    def windows_grant(repository, codec)
      platform = Platform.load(root: repository, name: 'qemu-virt')
      source = DisplayDomain.manifest(platform.site_manifest_source(repository, keep: [DisplayDomain::DOMAIN]))
                            .sub("  parameter pixels #{DisplayDomain::PIXELS}\n", WINDOWS_PARAMETERS)
      arguments = ManifestContextFixture.manifest_arguments(codec, source)
      context = Manifest::Context.new(**arguments, platform: platform_of(repository, 'qemu-virt'))
      planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
      Manifest.admit(source: source, codec: codec, context: context, planner: planner).bytes
    end

    # The development manifest with its grant of inspect to root's template naming two of
    # the interface's operations, INSPECT_OPERATIONS, out of number order, as the check packs it.
    def operations_grant(source, codec, platform)
      granted = source.sub("  service @service.inspect\n  operations none\n", "  service @service.inspect\n  operations #{INSPECT_OPERATIONS}\n")
      raise Error, 'the development manifest has no inspect grant of operations none' if granted == source

      Manifest.admit(source: granted, codec: codec, context: Manifest::Context.new(**ManifestContextFixture.arguments(codec), platform: platform),
                     planner: ManifestContextFixture.accepting_planner).bytes
    end

    # The development manifest on QEMU virt with its session template's grant of net
    # stating NET_PARAMETERS, as the check packs it.
    def net_grant(repository, codec)
      grant = "facet net\n  grantee @session.system\n  service @service.net\n"
      source = Platform.load(root: repository, name: 'qemu-virt').manifest_source(repository)
      raise Error, 'the development manifest grants no net to its session template' unless source.include?(grant)

      context = Manifest::Context.new(**ManifestContextFixture.arguments(codec), platform: platform_of(repository, 'qemu-virt'))
      Manifest.admit(source: source.sub(grant) { grant + NET_PARAMETERS }, codec: codec, context: context,
                     planner: ManifestContextFixture.accepting_planner).bytes
    end

    # The configured domains' manifest (ManifestContextFixture.domain_source) on QEMU virt
    # with alpha granted the ble service beta serves, naming BLE_SERVICES
    # (ManifestContextFixture.ble_grant), as the check packs it over a context whose
    # abi/gatt declares them.
    def ble_grant(source, codec, platform)
      context = Manifest::Context.new(**ManifestContextFixture.arguments(codec), platform: platform,
                                                                               gatt_services: ManifestContextFixture::GATT_NAMES)
      Manifest.admit(source: ManifestContextFixture.domain_source(source) + ManifestContextFixture.ble_grant(BLE_SERVICES),
                     codec: codec, context: context, planner: ManifestContextFixture.accepting_planner).bytes
    end

    # The configured domains' manifest (ManifestContextFixture.domain_source) on QEMU virt
    # with two more UARTs, alpha granted the line on the first
    # (ManifestContextFixture.with_line), as the check packs it.
    def line_grant(repository, codec)
      source = Platform.load(root: repository, name: 'qemu-virt').manifest_source(repository)
      grant = ManifestContextFixture.line_grant('line', '@domain.alpha', LINE_UART, floor: codec.constant('files_max_frame_min'))
      context = Manifest::Context.new(**ManifestContextFixture.arguments(codec),
                                      platform: ManifestContextFixture.line_platform(platform_of(repository, 'qemu-virt')))
      Manifest.admit(source: ManifestContextFixture.with_line(ManifestContextFixture.domain_source(source), grant),
                     codec: codec, context: context, planner: ManifestContextFixture.accepting_planner).bytes
    end

    # The configured domains' manifest with PACKAGE_ROWS, the system tree the apps row
    # needs, held by beta, room for the apps row in max_domains and root_memory, and a
    # development key.
    def packages(source, codec, platform)
      arguments = ManifestContextFixture.arguments(codec)
      artifacts = %w[clock quotes].to_h do |name|
        ["package-#{name}", { 'kind' => 'package', 'name' => name, 'memory' => 4096, 'sha256' => 'ab' * 32, 'gatt' => [] }]
      end
      context = Manifest::Context.new(**arguments, platform: platform, artifacts: arguments.fetch(:artifacts).merge(artifacts),
                                                   development_key: "\x07".b * 32)
      roomy = ManifestContextFixture.domain_source(source).sub(/^(  max_domains )(\d+)$/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).to_i + 2}" }
                                                         .sub(/^(  root_memory )(\d+)$/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).to_i + 1_048_576}" }
      source = ManifestContextFixture.with_system_tree(roomy, holder: '@domain.beta') + PACKAGE_ROWS
      Manifest.admit(source: source, codec: codec, context: context, planner: ManifestContextFixture.accepting_planner).bytes
    end

    # The platform record of the board NAME, whose machine its manifest is packed for.
    def platform_of(repository, name) = Platform.load(root: repository, name: name).record

    # The manifest bytes with the machine's boot_timeout_s, in their header, set to seconds.
    def boot_timeout(codec, bytes, seconds)
      header = codec.decode_layout('erx_manifest', bytes, offset: 0, prefix: true)
      encoded = codec.encode_layout('erx_manifest', header.merge('boot_timeout_s' => seconds))
      bytes.b.tap { |copy| copy[0, encoded.bytesize] = encoded }
    end
  end
end
