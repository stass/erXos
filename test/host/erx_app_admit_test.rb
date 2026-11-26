# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/fuzz/package_seeds'

# Runs test/erlang/erx_app_admit_tests.erl, the EUnit cases of admission, erx_app_admit
# (docs/design-packaging.md, "Admission"), compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Each case is a package
# file written here through the encoder erx_pkg_header's tests use (Erx::PackageSeeds),
# decoded by erx_pkg_header and admitted: each refusal of the design with its accepting
# neighbour, and for each two adjacent checks a header both refuse, answered by the earlier.
# Each fault of FAULTS replaces one passage of one source, and the cases must then fail.
class ErxAppAdmitTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  MODULE = File.join(ROOT, 'erlang/apps/erx_domain/src/erx_app_admit.erl')
  DOMAIN_CORE = File.join(ROOT, 'erlang/apps/erx_domain/src/erx_domain_core.erl')
  SOURCES = [MODULE, DOMAIN_CORE] +
            %w[erlang/apps/erx_domain/src/erx_ident.erl
               erlang/apps/erx/src/erx_pkg_header.erl otp/erts/preloaded/src/erx_verity_tree.erl
               build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl
               test/erlang/erx_app_admit_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  # A seeded fault: the passage `from` of the source `file` replaced by `to`.
  Fault = Data.define(:file, :from, :to)
  # The design's seeded faults, and those of the order and the name rule: the subset test of
  # step 6 dropped, which admits a need the row lacks; root no longer kept by session naming;
  # steps 4 and 5 swapped, which answers memory for a name another signer holds; the
  # identifier rule reduced to its length bound, which admits any byte; the file check's signer
  # ignored, the admitted package carrying `development` whatever key signed it. And PK13's: steps
  # 7 and 8 each dropped; step 8 counting the app's own package, which refuses every update;
  # a crafted header's repeated name kept twice.
  FAULTS = {
    'signer ignored' => Fault.new(file: MODULE, from: '      signer => Signer}.', to: '      signer => development}.'),
    'step 6 dropped' => Fault.new(file: MODULE, from: '[] -> refuse({not_offered, Need})',
                                  to: '[] -> #{row => 0, windows => false}'),
    'step 7 dropped' => Fault.new(file: MODULE, from: '[Service | _] -> refuse({gatt_not_offered, Service})',
                                  to: '[_ | _] -> ok'),
    'step 8 dropped' => Fault.new(file: MODULE, from: '[Service | _] -> refuse({gatt_taken, Service, map_get(Service, Holders)})',
                                  to: '[_ | _] -> ok'),
    'own name counted as taken' => Fault.new(file: MODULE, from: 'check_gatt_free(Gatt, maps:remove(Name, Held))',
                                             to: 'check_gatt_free(Gatt, Held)'),
    'gatt not taken as a set' => Fault.new(file: MODULE, from: 'Gatt = lists:usort(Declared)', to: 'Gatt = Declared'),
    'root not kept' => Fault.new(file: DOMAIN_CORE, from: "session_reserved(?SYSTEM_PREFIX) ->\n    true;\n", to: ''),
    'steps 4 and 5 swapped' =>
      Fault.new(file: MODULE,
                from: "    check_entry(Name, Signer, Max, Registry),\n    check_memory(Memory, Budget),\n",
                to: "    check_memory(Memory, Budget),\n    check_entry(Name, Signer, Max, Registry),\n"),
    'identifier rule reduced to its length' =>
      Fault.new(file: MODULE,
                from: "    case erx_ident:new(Bin) of\n        {error, bad_identifier} -> false;\n        _ -> true\n    end.",
                to: '    byte_size(Bin) =< 63.')
  }.freeze

  Seeds = Erx::PackageSeeds
  Tuple = Data.define(:items)

  def test_admission_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_a_case
    FAULTS.each do |name, fault|
      assert_equal 1, File.read(fault.file).scan(fault.from).size, "#{name}: the passage occurs once"
      output, = eunit(fault)
      assert_match(/Failed: [1-9]\d*\./, output, "#{name} failed no case")
    end
  end

  private

  MIB = 1_048_576
  MAX_NAME = 60 # 63 bytes less the 3 of "_64", erx_domain_core's names quota as a pooled suffix
  # The app template's facet rows in the EUnit module's manifest: packages, then the apps
  # row's services display (windows), data and panel (windows), then system, which every
  # admitted app holds, then ble, which offers the GATT services hrm and nus.
  PACKAGES, DISPLAY, DATA, PANEL, SYSTEM, BLE = 7, 8, 9, 10, 11, 12

  # A package's declaration, with gatt written as given: the packer refuses a repeated name,
  # so one that repeats is a crafted header's.
  def package(name, needs: %w[display data], gatt: [], memory: 64 * MIB, edits: ->(values) { values })
    declaration = Seeds::ERLANG.with(name: name, needs: needs, gatt: gatt, memory: memory)
    Seeds.sample(name, declaration: declaration, image_blocks: 3, tree_blocks: 1, edits: edits)
  end

  # Each case: the package, the signer the file check names, the manifest and registry the
  # EUnit module calls Context, and the answer.
  def cases
    accepted + refused
  end

  def accepted
    [[package('dashboard'), 'vendor', :base, ok([PACKAGES, DISPLAY, DATA], 'display')],
     [package('notes', needs: %w[data]), :development, :base, ok([PACKAGES, DATA], :none)],
     [package('board', needs: %w[display panel]), :development, :base, ok([PACKAGES, DISPLAY, PANEL], :none)],
     [package('kiosk', needs: []), :image, :base, ok([PACKAGES], :none)],
     [package('clock'), 'vendor', :base, ok([PACKAGES, DISPLAY, DATA], 'display')],
     [package('clock', needs: %w[panel]), 'vendor', :full, ok([PACKAGES, PANEL], 'panel')],
     [package('a' * MAX_NAME), :development, :base, ok([PACKAGES, DISPLAY, DATA], 'display')],
     [package('room_a'), :development, :base, ok([PACKAGES, DISPLAY, DATA], 'display')],
     [package('min_memory', memory: Seeds.codec.constant('app_memory_min')), :development, :base,
      ok([PACKAGES, DISPLAY, DATA], 'display', memory: Seeds.codec.constant('app_memory_min'))],
     [package('max_memory', memory: 128 * MIB), :development, :base,
      ok([PACKAGES, DISPLAY, DATA], 'display', memory: 128 * MIB)]] + gatt_accepted
  end

  # Steps 7 and 8 admit: a service the row offers and no other app holds; the services the
  # app's own package holds, as an update keeps them; a crafted header's repeated name, once.
  def gatt_accepted
    [[package('beacon', gatt: %w[nus]), :development, :base, ok([PACKAGES, DISPLAY, DATA], 'display', gatt: %w[nus])],
     [package('clock', gatt: %w[hrm nus]), 'vendor', :base, ok([PACKAGES, DISPLAY, DATA], 'display', gatt: %w[hrm nus])],
     [package('twice', gatt: %w[nus nus]), :development, :base, ok([PACKAGES, DISPLAY, DATA], 'display', gatt: %w[nus])]]
  end

  # Step 7 refuses a service the row does not offer, every service of a row without ble;
  # step 8 one another app's package holds; each step judges the whole set before the next.
  def gatt_refused
    [[package('battery', gatt: %w[bas]), :development, :base, error(Tuple.new([:gatt_not_offered, 'bas']))],
     [package('beacon', gatt: %w[nus]), :development, :no_ble, error(Tuple.new([:gatt_not_offered, 'nus']))],
     [package('heart', gatt: %w[nus hrm]), :development, :base, error(Tuple.new([:gatt_taken, 'hrm', 'clock']))],
     [package('nettie', needs: %w[net], gatt: %w[bas]), :development, :base, # 6 before 7
      error(Tuple.new([:not_offered, 'net']))],
     [package('pulse', gatt: %w[hrm zzz]), :development, :base, # 7 before 8
      error(Tuple.new([:gatt_not_offered, 'zzz']))]]
  end

  def refused
    abi = Seeds.codec.abi_version
    min = Seeds.codec.constant('app_memory_min')
    [[package('dashboard'), :development, :no_apps, error(:no_apps)],
     [package('abi', edits: ->(values) { values.merge('abi_version' => abi + 1) }), :development, :base,
      error(Tuple.new([:abi, abi + 1, abi]))],
     # A header built for another architecture: its arch field names the string of its name.
     [package('riscv64', edits: ->(values) { values.merge('arch' => values['name']) }), :development, :base,
      error(Tuple.new([:arch, 'riscv64', Seeds::ARCH]))],
     # The first check that fails answers: an ABI mismatch before a reserved name.
     [package('alice', edits: ->(values) { values.merge('abi_version' => abi + 1) }), :development, :base,
      error(Tuple.new([:abi, abi + 1, abi]))],
     [package('root'), :development, :base, error(Tuple.new([:bad_name, 'root']))],
     [package('root_1'), :development, :base, error(Tuple.new([:bad_name, 'root_1']))],
     [package('alice_2'), :development, :base, error(Tuple.new([:bad_name, 'alice_2']))],
     [package('a' * (MAX_NAME + 1)), :development, :base, error(Tuple.new([:bad_name, 'a' * (MAX_NAME + 1)]))],
     [package('alice'), :development, :base, error(Tuple.new([:name_taken, 'alice']))],
     [package('storage'), :development, :base, error(Tuple.new([:name_taken, 'storage']))],
     [package('display'), :development, :base, error(Tuple.new([:name_taken, 'display']))],
     [package('kiosk'), 'vendor', :base, error(Tuple.new([:name_taken, 'kiosk']))],
     [package('clock'), :development, :base, error(Tuple.new([:signer_changed, 'clock']))],
     [package('dashboard'), :development, :full, error(:apps_full)],
     [package('low', memory: min - 1), :development, :base, error(Tuple.new([:memory, min - 1]))],
     [package('high', memory: (128 * MIB) + 1), :development, :base, error(Tuple.new([:memory, (128 * MIB) + 1]))],
     [package('netuser', needs: %w[display net]), :development, :base, error(Tuple.new([:not_offered, 'net']))],
     [package('pkgs', needs: %w[packages]), :development, :base, error(Tuple.new([:not_offered, 'packages']))],
     # No apps row offers a service of the media interface; the manifest check refuses one that does.
     [package('drives', needs: %w[media]), :development, :base, error(Tuple.new([:not_offered, 'media']))]] +
      earlier_check_answers
  end

  # For each two adjacent checks of the first six, a header both refuse, answered by the earlier
  # (gatt_refused holds 6 before 7 and 7 before 8).
  def earlier_check_answers
    abi = Seeds.codec.abi_version
    newer_abi = ->(values) { values.merge('abi_version' => abi + 1) }
    long = 'a' * (MAX_NAME + 1)
    [[package('two_1', edits: newer_abi), :development, :no_apps, error(:no_apps)], # 1 before 2 (and 3)
     [package(long, edits: newer_abi), :development, :base, error(Tuple.new([:abi, abi + 1, abi]))], # 2 before 3
     # 3 before 4: full holds every entry
     [package('storage'), :development, :full, error(Tuple.new([:name_taken, 'storage']))],
     [package('clock', memory: Seeds.codec.constant('app_memory_min') - 1), :development, :base, # 4 before 5
      error(Tuple.new([:signer_changed, 'clock']))],
     [package('high', needs: %w[net], memory: (128 * MIB) + 1), :development, :base, # 5 before 6
      error(Tuple.new([:memory, (128 * MIB) + 1]))]] + gatt_refused
  end

  # An admission's answer: the kept rows with system, and the ble row with the services
  # admitted, or none when the declaration names no gatt.
  def ok(rows, display, memory: 64 * MIB, gatt: [])
    ble = gatt.empty? ? :none : { row: BLE, gatt: gatt }
    Tuple.new([:ok, { rows: (rows + [SYSTEM]).sort, ble: ble, display: display, memory: memory }])
  end

  def error(reason) = Tuple.new([:error, reason])

  def term(value)
    case value
    in Tuple(items:) then "{#{items.map { |item| term(item) }.join(', ')}}"
    in Symbol then value.to_s
    in Integer then value.to_s
    in String then "<<\"#{value}\">>"
    in Array then "[#{value.map { |item| term(item) }.join(', ')}]"
    in Hash then "\#{#{value.map { |key, item| "#{key} => #{term(item)}" }.join(', ')}}"
    end
  end

  # Compiles SOURCES, with fault's file replaced by its faulted copy, and runs the cases:
  # each case's file bytes in a directory of its own as NNN.bin, and cases.term.
  def eunit(fault = nil)
    Dir.mktmpdir('erx-app-admit-test') do |work|
      lines = cases.each_with_index.map do |(sample, signer, context, answer), index|
        name = format('%03d_%s', index, sample.name.byteslice(0, 16))
        File.binwrite(File.join(work, "#{name}.bin"), sample.prefix)
        "{\"#{name}\", #{sample.length}, #{term(signer)}, #{context}, #{term(answer)}}.\n"
      end
      File.write(File.join(work, 'cases.term'), lines.join)
      sources = SOURCES.map { |path| fault&.file == path ? faulted(fault, work) : path }
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, *sources, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_ADMIT_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_app_admit_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end

  # Writes fault's file with its passage replaced into work, under the same name, and
  # answers the copy's path.
  def faulted(fault, work)
    File.join(work, File.basename(fault.file)).tap do |copy|
      File.write(copy, File.read(fault.file).sub(fault.from, fault.to))
    end
  end
end
