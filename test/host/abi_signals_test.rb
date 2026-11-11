# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/dependencies'

# The signal table of the ABI file (abi/signals.txt) against FreeBSD 15.1's
# sys/sys/signal.h at deps.lock's freebsd-signal pin, read through the
# generated header (docs/design-programs.md, "Signal numbers"), and the
# generated C lookups run over every number around the table's range.
class AbiSignalsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The one alias erXos adds to FreeBSD's names: SIGPOLL, Linux's name of SIGIO.
  OWN_ALIASES = { 'POLL' => 23 }.freeze
  SIGNAL_DEFINE = /^#define\s+SIG([A-Z0-9]+)\s+(\d+|SIG[A-Z0-9]+)\b/
  GENERATED_DEFINE = /^#define ERX_SIG([A-Z0-9]+) INT32_C\((\d+)\)$/
  DEADLINE = '60'
  LIMIT = ['gtimeout', '-k', '10', DEADLINE].freeze

  def test_signal_names_and_numbers_match_freebsd
    assert_equal freebsd, generated(ROOT)
  end

  # Seeded fault: a table that swaps SIGINFO's and SIGUSR1's numbers is well
  # formed, so only the comparison with FreeBSD refuses it.
  def test_comparison_catches_a_wrong_number
    Dir.mktmpdir('erx-abi-signals-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/signals.txt')
      text = File.read(path)
      seeded = text.sub(/^signal info 29 /, 'signal info 30 ').sub(/^signal usr1 30 /, 'signal usr1 29 ')
      refute_equal text, seeded
      File.write(path, seeded)
      table = generated(root)
      assert_equal [30, 29], table.values_at('INFO', 'USR1')
      refute_equal freebsd, table
    end
  end

  # erx_sig_valid holds for 1 to 31 and 65 to 126 only; erx_sig_name and
  # erx_sig_action answer for every listed number, reserved ones included.
  def test_generated_c_lookups
    Dir.mktmpdir('erx-abi-signals-c-') do |work|
      header = File.join(work, 'erx/abi.h')
      FileUtils.mkdir_p(File.dirname(header))
      File.write(header, header_of(ROOT))
      source = File.join(work, 'lookups.c')
      File.write(source, <<~C)
        #include <stdio.h>
        #include <erx/abi.h>

        int
        main(void)
        {
        	for (int n = -1; n <= 200; n++) {
        		const char *name = erx_sig_name(n);

        		printf("%d %d %d %s\\n", n, erx_sig_valid(n), erx_sig_action(n), name ? name : "-");
        	}
        	return (0);
        }
      C
      binary = File.join(work, 'lookups')
      execute(*LIMIT, ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-I', work,
          '-o', binary, source)
      rows = execute(*LIMIT, binary).lines.map(&:split)
      valid = rows.select { |row| row[1] == '1' }.map { |row| Integer(row[0]) }
      assert_equal [*1..31, *65..126], valid
      named = rows.to_h { |row| [Integer(row[0]), row[3]] }
      assert_equal %w[HUP STOP INFO THR LIBRT RTMIN RTMIN+1 RTMIN+30 RTMAX-30 RTMAX -],
                   named.values_at(1, 17, 29, 32, 33, 65, 66, 95, 96, 126, 34)
      actions = rows.to_h { |row| [Integer(row[0]), Integer(row[2])] }
      expected = { 0 => 'NONE', 1 => 'TERMINATE', 16 => 'IGNORE', 17 => 'STOP', 19 => 'CONTINUE',
                   23 => 'IGNORE', 32 => 'RESERVED', 64 => 'NONE', 126 => 'TERMINATE', 127 => 'NONE' }
      assert_equal expected.transform_values { |action| action_value(action) }, actions.slice(*expected.keys)
    end
  end

  private

  def action_value(action)
    Integer(header_of(ROOT)[/^#define ERX_SIG_ACTION_#{action} INT32_C\((\d+)\)$/, 1])
  end

  # FreeBSD's signal names without SIG, aliases resolved to their numbers.
  def freebsd
    _, path = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-signal')
    defines = File.read(path).scan(SIGNAL_DEFINE).to_h
    defines.transform_values do |value|
      value.start_with?('SIG') ? Integer(defines.fetch(value.delete_prefix('SIG'))) : Integer(value)
    end.sort.to_h
  end

  # The table's names and aliases without SIG, as the generated header numbers them.
  def generated(root)
    header_of(root).scan(GENERATED_DEFINE).to_h { |name, number| [name, Integer(number)] }
          .reject { |name, number| OWN_ALIASES[name] == number }.sort.to_h
  end

  # The generated erx/abi.h of the ABI files beneath root, from the model and
  # the C emitter alone, so a seeded copy of abi/ needs no other input.
  def header_of(root)
    Erx::ABI::CEmitter.header(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64')))
  end

  def execute(*argv)
    output, status = Open3.capture2e(*argv, stdin_data: '')
    assert status.success?, "#{argv.first(5).join(' ')} failed:\n#{output}"
    output
  end
end
