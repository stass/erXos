# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/manifest_seeds'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'

# A facet row's parameters reach the mint (docs/design-system.md, "Facets a configured
# domain serves"): the manifest fuzz target's windows-grant seed, the display_domain
# suite's manifest with its client template's grant of the display stating pixels,
# windows and clipboard (Erx::ManifestSeeds.windows_grant), is packed by the manifest check;
# the domain library's boot view (liberx/system/dom_boot_view.c) is built from those
# bytes, and the NIF's erx_domain_served_terms
# (otp/erts/emulator/nifs/erxos/erx_domain_terms.c) turns it into
# erx_domain_lib:configured/0's terms, through the host harness
# test/fixtures/erx_domain_terms_harness.c loaded into stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies), under test/erlang/erx_facet_parameters_tests.erl:
# the grant's limits carry each parameter by name, erx_domain_mints charges the display
# the row's pixel area, and the view refuses each forged parameter row of parameter_forgeries. The
# line-grant seed (Erx::ManifestSeeds.line_grant) takes the same road: its grant's device
# reaches the terms as the index of its UART's device row, and the manifest's reader, which
# the view reads through, refuses a device one past the device table. The net-grant seed
# (Erx::ManifestSeeds.net_grant) carries sets: its grant's ports, a full set of 16, and
# listen reach the terms as lists in ascending order, and the view refuses each forgery of
# NET_FORGED; it is the development manifest, whose usb row alone carries a drive, disk0,
# in erx_domain_drives_term's per-row drives. The operations seed (Erx::ManifestSeeds.operations_grant), root's template granted two
# of inspect's operations, takes the same road: the grant's limits carry their names in
# number order, and the view refuses each forgery of operation_forgeries, one naming
# operations on a service a configured domain serves. Seeded faults that drop a parameter
# or an operation on the way, admit a value out of bound, an undeclared operation or an
# operation of a configured domain's service, a parameter of another key or kind than its
# declaration's, or let a set pass unsorted or past its most,
# must each fail a case.
class FacetParametersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  TERMS = File.join(NIFS, 'erx_domain_terms.c')
  VIEW = File.join(ROOT, 'liberx/system/dom_boot_view.c')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_domain_terms_harness.c')
  LIBRARY = %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/erx_lane.c
               liberx/backend/core/boot_manifest.c].map { |path| File.join(ROOT, path) }.freeze
  TESTS = %w[test/erlang/erx_facet_parameters_tests.erl].freeze
  LIMITS_CASE = 'the_grant_s_limits_carry_its_parameters_by_name_test'
  FORGED_CASE = 'forged_parameter_rows_are_refused_test'
  OPERATIONS_CASE = 'the_grant_s_limits_carry_its_operations_by_name_test'
  FORGED_OPERATIONS_CASE = 'forged_operation_rows_are_refused_test'
  LINE_CASE = 'the_line_grant_s_device_is_its_device_row_test'
  NET_CASE = 'the_net_grant_s_sets_are_lists_test'

  # The grant's packed parameter rows are windows (key 1), pixels (2) and clipboard (3), the
  # display facet's only ones, 32 bytes each: key u32 at 0, kind u32 at 4, scalar u64 at 8.
  # Each forgery edits the rows, given as an array of their bytes, and the view must refuse it;
  # parameter_forgeries adds the one that renames a row to a key the interface does not declare.
  FORGED = {
    'out-of-order' => ->(rows) { rows[0], rows[1] = rows[1], rows[0] },
    'stated-twice' => ->(rows) { rows[1] = rows[0].dup },
    'other-kind' => ->(rows) { rows[0][4, 4] = [2].pack('V') },
    'below-its-bound' => ->(rows) { rows[1][8, 8] = [4095].pack('Q<') }
  }.freeze

  # The net grant's rows are sockets (key 1), its 16 ports (3) in ascending order and listen
  # (4), 18 in all. Each forgery breaks the set's order or its most.
  NET_FORGED = {
    'set-unsorted' => ->(rows) { rows[1], rows[2] = rows[2], rows[1] },
    'set-repeated' => ->(rows) { rows[2] = rows[1].dup },
    'set-past-its-most' => ->(rows) { rows[17] = [3, 1, 2016].pack('VVQ<') + rows[17].byteslice(16, 16) }
  }.freeze

  # The operations seed's grant of inspect packs inspect (1) and entries (2), 4 bytes
  # each: operation u32 at 0. Each forgery edits the rows, or, for configured-server, the
  # inspect service's row, and the view must refuse it; operation_forgeries adds the one that
  # renames a row to an operation the interface does not declare.
  FORGED_OPERATIONS = {
    'out-of-order' => ->(rows) { rows[0], rows[1] = rows[1], rows[0] },
    'named-twice' => ->(rows) { rows[1] = rows[0].dup },
    'configured-server' => :configured_server
  }.freeze

  # The ABI layout of a row of each of a facet's tables.
  ROW_LAYOUTS = { 'parameters' => 'erx_mf_parameter', 'operations' => 'erx_mf_operation' }.freeze

  def test_a_packed_row_reaches_the_mint
    assert_match(/^  All 8 tests passed\.$/, run_cases)
  end

  # A seeded fault: the file it edits, the anchor found once there, its replacement and
  # the case that must fail on it.
  MUTANTS = {
    'the view drops a facet\'s last parameter' =>
      [VIEW, '.parameters = &parameters[first], .nparameters = facet.parameters.count };',
       '.parameters = &parameters[first], .nparameters = facet.parameters.count - (facet.parameters.count != 0) };',
       LIMITS_CASE],
    'the terms leave the parameters out' =>
      [TERMS, 'for (uint32_t at = 0; at < facet->nparameters; at += taken) {', 'for (uint32_t at = 0; at < 0; at += taken) {',
       LIMITS_CASE],
    'the view admits a value out of its bound' =>
      [VIEW, 'return (within ? NULL : "manifest: a facet parameter is outside its declared bound");', 'return ((void)within, NULL);',
       FORGED_CASE],
    'the view drops a device reference' =>
      [VIEW, 'value->index = row->index;', 'value->index = 0;', LINE_CASE],
    'the terms give a device reference\'s scalar' =>
      [TERMS, 'enif_make_uint(env, parameter->index)', 'enif_make_uint(env, (unsigned)parameter->scalar)', LINE_CASE],
    'the view admits an undeclared operation' =>
      [VIEW, 'if (row.operation == declared[at].number)', 'if (row.operation != 0)', FORGED_OPERATIONS_CASE],
    'the view admits operations of a configured domain\'s service' =>
      [VIEW, 'if (count != 0 && service->server != ERX_MF_NONE)', 'if (count != 0 && service->server == 0xdeadbeef)',
       FORGED_OPERATIONS_CASE],
    'the view drops a facet\'s last operation' =>
      [VIEW, '.operations = &operations[named], .noperations = facet.operations.count,',
       '.operations = &operations[named], .noperations = facet.operations.count - (facet.operations.count != 0),',
       OPERATIONS_CASE],
    'the terms leave the operations out' =>
      [TERMS, 'for (uint32_t at = facet->noperations; at-- > 0;)', 'for (uint32_t at = 0; at-- > 0;)', OPERATIONS_CASE],
    'the view takes a row of another key as its declaration\'s' =>
      [VIEW, 'if (row.key != declared[at].number)', 'if (false)', FORGED_CASE],
    'the view takes a row of another kind than its declaration\'s' =>
      [VIEW, 'if (row->kind != parameter->kind)', 'if (false)', FORGED_CASE],
    'the view takes a set past its most' =>
      [VIEW, 'of < declared[at].most && matched < count', 'matched < count', FORGED_CASE],
    'the view takes a set unsorted' =>
      [VIEW, 'if (of > 0 && !boot_set_follows(&parameters[matched - 1], &parameters[matched]))', 'if ((void)boot_set_follows, false)',
       FORGED_CASE],
    'the terms give a set its first element alone' =>
      [TERMS, '*taken < count && parameters', '*taken < 1 && parameters', NET_CASE]
  }.freeze

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, (file, anchor, replacement, catching_case)|
      source = File.read(file)
      assert_equal 1, source.scan(anchor).size, "mutant #{name} must edit exactly one place"
      output = run_cases(file => source.sub(anchor, replacement))
      assert_match(/erx_facet_parameters_tests: #{catching_case}[^\n]*\*failed\*/, output, "seeded fault not caught: #{name}")
    end
  end

  private

  def codec = @codec ||= Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
  def manifest = @manifest ||= Erx::ManifestSeeds.windows_grant(ROOT, codec)
  def line_manifest = @line_manifest ||= Erx::ManifestSeeds.line_grant(ROOT, codec)
  def net_manifest = @net_manifest ||= Erx::ManifestSeeds.net_grant(ROOT, codec)

  def operations_manifest
    @operations_manifest ||= Erx::ManifestSeeds.operations_grant(
      Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT), codec, Erx::ManifestSeeds.platform_of(ROOT, 'qemu-virt')
    )
  end

  def configured_server(view)
    assert_operator view.count('domains'), :>, 0
    index = view.count('services').times.find { |at| view.fetch('services', at).fetch('interface') == codec.constant('service_inspect') }
    encoded = codec.encode_layout('erx_mf_service', view.fetch('services', index).merge('server' => 0))
    offset = view.header.fetch('services').fetch('offset') + (index * encoded.bytesize)
    operations_manifest.b.tap { |copy| copy[offset, encoded.bytesize] = encoded }
  end

  # The line manifest's device rows, by path, the index of the one its grant names.
  def line_device
    view = codec.open('manifest', line_manifest)
    view.count('devices').times.find { |index| view.string(view.fetch('devices', index).fetch('path')) == Erx::ManifestSeeds::LINE_UART }
  end

  # The line manifest with its grant's device row naming one past the device table.
  def line_past_the_table
    header = codec.open('manifest', line_manifest).header
    table = header.fetch('facet_parameters')
    device = codec.member('mf_parameter_kind', 'device')
    offset = table.fetch('count').times.map { |index| table.fetch('offset') + (index * 32) }.find do |at|
      codec.decode_layout('erx_mf_parameter', line_manifest, offset: at, prefix: true).fetch('kind') == device
    end
    row = codec.decode_layout('erx_mf_parameter', line_manifest, offset: offset, prefix: true)
    encoded = codec.encode_layout('erx_mf_parameter', row.merge('index' => header.fetch('devices').fetch('count')))
    line_manifest.b.tap { |copy| copy[offset, encoded.bytesize] = encoded }
  end

  # The ABI's declaration of the service named name (abi_contracts.rb).
  def declaration(name) = codec.schema.services.find { |service| service.fetch(:name) == name }

  # FORGED, and the forgery that renames the grant's last row, clipboard (3), to the key one
  # past the windows interface's last declared parameter: the rows stay in order and the key
  # alone is undeclared, whatever abi/services/windows.txt declares.
  def parameter_forgeries
    undeclared = declaration('windows').fetch(:parameters).values.map { |parameter| parameter.fetch(:number) }.max + 1
    FORGED.merge('undeclared' => ->(rows) { rows[2][0, 4] = [undeclared].pack('V') })
  end

  # FORGED_OPERATIONS, and the forgery that renames the grant's last row, entries (2), to the
  # operation one past inspect's last declared one: the rows stay in order and the operation
  # alone is undeclared.
  def operation_forgeries
    undeclared = declaration('inspect').fetch(:operations).values.max + 1
    FORGED_OPERATIONS.merge('undeclared' => ->(rows) { rows[1] = [undeclared].pack('V') })
  end

  # The operations manifest with its inspect grant's operation rows edited by forge, or,
  # for :configured_server, its inspect service served by configured row 0.
  def forged_operations_manifest(forge)
    return configured_server(codec.open('manifest', operations_manifest)) if forge == :configured_server

    forged(operations_manifest, 'inspect', 2, forge, table: 'operations')
  end

  # The rows of table, 'parameters' or 'operations', of the one facet of bytes named facet
  # that has any there, as their byte offset and count.
  def span(bytes, facet, table)
    view = codec.open('manifest', bytes)
    rows = view.count('facets').times.map { |index| view.fetch('facets', index) }
               .select { |row| view.string(row.fetch('name')) == facet && row.fetch(table).fetch('count').positive? }
    assert_equal 1, rows.size, "one facet #{facet} with #{table}"
    rows.first.fetch(table)
  end

  # The manifest bytes with the count rows of span(bytes, facet, table) edited by forge.
  def forged(bytes, facet, count, forge, table: 'parameters')
    rows_at = span(bytes, facet, table)
    assert_equal count, rows_at.fetch('count')
    offset = rows_at.fetch('offset')
    size = codec.layout_size(ROW_LAYOUTS.fetch(table))
    rows = Array.new(count) { |index| bytes.byteslice(offset + (index * size), size).b }
    forge.call(rows)
    bytes.b.tap { |copy| copy[offset, count * size] = rows.join }
  end

  # The cases' output, with the harness built from sources, each path's text as given
  # and the rest of the library as checked in. The forged manifests are refused-NAME.bin.
  def run_cases(sources = {})
    Dir.mktmpdir('erx-facet-parameters-') do |work|
      File.binwrite(File.join(work, 'manifest.bin'), manifest)
      parameter_forgeries.each { |name, forge| File.binwrite(File.join(work, "refused-#{name}.bin"), forged(manifest, Erx::DisplayDomain::SERVICE, 3, forge)) }
      NET_FORGED.each { |name, forge| File.binwrite(File.join(work, "refused-#{name}.bin"), forged(net_manifest, 'net', 18, forge)) }
      File.binwrite(File.join(work, 'net.bin'), net_manifest)
      File.binwrite(File.join(work, 'line.bin'), line_manifest)
      File.binwrite(File.join(work, 'operations.bin'), operations_manifest)
      operation_forgeries.each { |name, forge| File.binwrite(File.join(work, "forged-operations-#{name}.bin"), forged_operations_manifest(forge)) }
      File.write(File.join(work, 'line-device'), line_device.to_s)
      File.binwrite(File.join(work, 'unreadable-device-past-the-table.bin'), line_past_the_table)
      ErlangBuild.compile(work, applications: %w[erx_domain], tests: TESTS)
      build_nif(work, sources.to_h { |path, text| [path, File.join(work, File.basename(path)).tap { |copy| File.write(copy, text) }] })
      output, = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120',
                                ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                'halt(case eunit:test(erx_facet_parameters_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                chdir: work, stdin_data: '')
      output
    end
  end

  # erx_domain_terms_harness.so in work, against the headers of the emulator ERX_ERL runs.
  def build_nif(work, copies)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    sources = [TERMS, VIEW, HARNESS, *LIBRARY].map { |path| copies.fetch(path, path) }
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17',
                                     '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
                                     *Erx::HostOs::NIF_LINK_FLAGS, '-I', NIFS, '-I', File.join(root, 'usr/include'),
                                     *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'),
                                     '-I', ROOT, '-o', File.join(work, 'erx_domain_terms_harness.so'), *sources,
                                     Erx::Generated.path('liberx/generated/abi_reader.c', root: ROOT), stdin_data: '')
    assert status.success?, output
  end
end
