# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'terminal_rules'
require_relative 'output_directory'

module Erx
  module TerminalRules
    module_function

    def plan(root:)
      root = File.realpath(root)
      source_bytes = read_input(File.join(root, 'abi/terminal.txt'), maximum: 65_536)
      model = source(source_bytes)
      origin = Origin.new(root: File.join(root, 'otp')).check
      inputs = model.fetch('input').to_h do |name, path|
        bytes = read_input(File.join(root, path), maximum: 8 * 1024 * 1024)
        record = origin.fetch('files')[path.delete_prefix('otp/')]
        unless record && Digest::SHA256.hexdigest(bytes) == record.fetch('sha256')
          raise Error, 'terminal input differs from its pinned OTP origin'
        end
        [name, bytes]
      end
      renderer_operations = inputs.fetch('prim_tty').scan(/\bio_ansi:([a-z_]+)\(/).flatten.uniq.sort
      unless renderer_operations == model.fetch('renderer_operations').sort
        raise Error, 'prim_tty operations differ from terminal declaration'
      end
      styles = inputs.fetch('prim_tty').scan(/io_ansi:format\(\[((?:[a-z_]+,\s*)+)/).flatten
                     .flat_map { |prefix| prefix.split(',').map(&:strip).reject(&:empty?) }.uniq.sort
      raise Error, 'prim_tty styles differ from terminal declaration' unless styles == model.fetch('renderer_styles').sort
      intervals = unsafe_intervals(model, records: unicode_data(inputs.fetch('unicode_data')),
                                   ignorables: derived_properties(inputs.fetch('properties'), version: model.fetch('unicode')))
      catalog = model.select { |name, _| %w[pass token grammar parameter sgr literal sequence].include?(name) }
      catalog = catalog.merge('resets' => reset_sequences(model), 'unicode' => model.fetch('unicode'))
      files = { OUTPUTS[0] => ascii_header(model), OUTPUTS[1] => erlang_tables(intervals, catalog),
                OUTPUTS[2] => ruby_tables(intervals, catalog) }
      notice = inputs.fetch('properties').lines.take_while { |line| line.start_with?('#') || line.strip.empty? }.join
                     .force_encoding(Encoding::UTF_8)
      input_hashes = model.fetch('input').to_h { |name, path| [path, Digest::SHA256.hexdigest(inputs.fetch(name))] }
      provenance = { 'version' => 1, 'unicode' => model.fetch('unicode'), 'license' => 'Unicode-3.0',
                     'origin' => 'otp/ORIGIN.md', 'inputs' => input_hashes,
                     'original_unicode_notice' => notice }
      files[OUTPUTS[3]] = JSON.pretty_generate(provenance, ascii_only: true) + "\n"
      generators = %w[tools/lib/erx/terminal_rules.rb tools/lib/erx/terminal_generation.rb tools/gen_terminal.rb]
      hashes = (generators + ['abi/terminal.txt', 'otp/ORIGIN.md']).to_h do |path|
        [path, Digest::SHA256.file(File.join(root, path)).hexdigest]
      end.merge(input_hashes)
      files[OUTPUTS[4]] = JSON.pretty_generate('version' => 1, 'inputs' => hashes.sort.to_h,
                                              'outputs' => OUTPUTS.sort) + "\n"
      raise Error, 'generated terminal output is not ASCII' unless files.values.all?(&:ascii_only?)
      files.sort.to_h.transform_values(&:freeze).freeze
    rescue SystemCallError => error
      raise Error, "cannot read terminal generation input: #{error.message}"
    end

    def reset_sequences(model)
      separator = model.fetch('grammar').fetch('separator').chr
      model.fetch('reset').to_h do |name, reset|
        key = 'terminal_mode/' + reset.fetch('sequence')
        bytes = if model.fetch('literal').key?(key)
                  model.fetch('literal').fetch(key).fetch('bytes')
                else
                  row = model.fetch('sequence').fetch(key)
                  row.fetch('introducer') + row.fetch('private') +
                    reset.fetch('parameters').join(separator).bytes + row.fetch('intermediate') + [row.fetch('final')]
                end
        [name, bytes]
      end
    end
    private_class_method :reset_sequences

    def ascii_header(model)
      first, last = model.fetch('kernel_ascii').fetch('range')
      values = (0..255).map { |byte| byte.between?(first, last) ? 1 : 0 }
      rows = values.each_slice(16).map { |slice| "\t" + slice.join(', ') + ',' }
      token = model.fetch('token').fetch('kernel')
      unless token.fetch('minimum') == token.fetch('maximum') && token.fetch('suffix').empty?
        raise Error, 'the kernel escape token must be a prefix and a fixed count of hex digits'
      end
      prefix = token.fetch('prefix').gsub(/[\\"]/) { |character| "\\#{character}" }
      "/*\n * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        " * SPDX-License-Identifier: BSD-2-Clause\n * Generated from abi/terminal.txt; do not edit.\n */\n\n" \
        "#ifndef ERX_TERMINAL_ASCII_H\n#define ERX_TERMINAL_ASCII_H\n\n#include <stdint.h>\n\n" \
        "/* A byte index is always in bounds; values grant kernel text passthrough. */\n" \
        "static const uint8_t erx_terminal_ascii_safe[256] = {\n#{rows.join("\n")}\n};\n\n" \
        "/* A byte outside the class is written as this prefix and uppercase hex digits. */\n" \
        "#define ERX_TERMINAL_KERNEL_TOKEN_PREFIX \"#{prefix}\"\n" \
        "#define ERX_TERMINAL_KERNEL_TOKEN_DIGITS #{token.fetch('minimum')}\n\n#endif\n"
    end
    private_class_method :ascii_header

    def ruby_tables(intervals, catalog)
      "# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        "# SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
        "# Generated from abi/terminal.txt and pinned OTP Unicode data; do not edit.\n" \
        "# Unicode notice and exact input identities: terminal_notices.json.\n# frozen_string_literal: true\n\n" \
        "module Erx\n  module Generated\n    module TerminalTables\n" \
        "      UNICODE_UNSAFE_RANGES = #{ruby_value(intervals)}\n" \
        "      CATALOG = #{ruby_value(catalog)}\n    end\n  end\nend\n"
    end
    private_class_method :ruby_tables

    def ruby_value(value)
      case value
      when Hash then '{' + value.sort.map { |key, member| "#{JSON.generate(key)} => #{ruby_value(member)}" }.join(",\n        ") + '}.freeze'
      when Array
        separator = value.any? { |member| member.is_a?(Array) || member.is_a?(Hash) } ? ",\n        " : ', '
        '[' + value.map { |member| ruby_value(member) }.join(separator) + '].freeze'
      when String then JSON.generate(value, ascii_only: true) + '.freeze'
      else value.inspect
      end
    end
    private_class_method :ruby_value

    def erlang_tables(intervals, catalog)
      "%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        "%% SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
        "%% Generated from abi/terminal.txt and pinned OTP Unicode data; do not edit.\n" \
        "%% Unicode notice: tools/generated/terminal_notices.json.\n" \
        "-module(erx_text_tables).\n-export([unicode_unsafe_ranges/0, catalog/0]).\n\n" \
        "%% A tuple supports bounded binary search without constructing an index.\n" \
        "unicode_unsafe_ranges() ->\n    {" + intervals.map { |first, last| "{16##{first.to_s(16)}, 16##{last.to_s(16)}}" }.join(",\n     ") + "}.\n\n" \
        "%% Names remain binaries; no source-derived atom is created.\n" \
        "catalog() ->\n    #{erlang_value(catalog)}.\n"
    end
    private_class_method :erlang_tables

    def erlang_value(value)
      case value
      when Hash then '#{' + value.sort.map { |key, member| "#{erlang_value(key)} => #{erlang_value(member)}" }.join(",\n      ") + '}'
      when Array then '[' + value.map { |member| erlang_value(member) }.join(', ') + ']'
      when String then '<<' + JSON.generate(value, ascii_only: true) + '>>'
      else value.inspect
      end
    end
    private_class_method :erlang_value

    def output_inventory(root:)
      patterns = ['include/erx/terminal*.h', 'erlang/apps/erx/src/erx_text_tables*',
                  'tools/generated/terminal*', 'abi/terminal_generated*']
      patterns.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
              .map { |path| path.delete_prefix(root + '/') }.sort
    end
    private_class_method :output_inventory

    def check(plan, root:)
      validate_output_plan(plan)
      root = File.realpath(root)
      preflight_outputs(plan, root: root)
      Dir.mktmpdir('erx-terminal-check-') do |temporary|
        plan.each do |path, bytes|
          target = File.join(temporary, path)
          OutputDirectory.prepare(root: temporary, path: File.dirname(target))
          File.binwrite(target, bytes)
        end
        stale = (plan.keys | output_inventory(root: root)).select do |relative|
          path = File.join(root, relative)
          !plan.key?(relative) || File.symlink?(path) || !File.file?(path) ||
            File.binread(path) != File.binread(File.join(temporary, relative))
        end
        raise Error, "terminal generation drift: #{stale.join(', ')}" unless stale.empty?
      end
      true
    end

    def publish(plan, root:)
      validate_output_plan(plan)
      root = File.realpath(root)
      inventory = preflight_outputs(plan, root: root)
      plan.each do |relative, bytes|
        target = File.join(root, relative)
        directory = OutputDirectory.prepare(root: root, path: File.dirname(target))
        temporary = File.join(directory, ".#{File.basename(target)}-#{Process.pid}.tmp")
        created = false
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
            created = true
            file.write(bytes)
          end
          File.rename(temporary, target)
        ensure
          File.unlink(temporary) if created && File.file?(temporary) && !File.symlink?(temporary)
        end
      end
      (inventory - plan.keys).each do |relative|
        path = File.join(root, relative)
        raise Error, 'unexpected directory among terminal outputs' if File.directory?(path) && !File.symlink?(path)
        File.unlink(path)
      end
      true
    rescue SystemCallError => error
      raise Error, "cannot publish terminal tables: #{error.message}"
    end

    def preflight_outputs(plan, root:)
      plan.each_key do |relative|
        OutputDirectory.check(root: root, path: File.dirname(File.join(root, relative)))
      end
      inventory = output_inventory(root: root)
      (plan.keys | inventory).each do |relative|
        path = File.join(root, relative)
        if File.exist?(path) && !File.symlink?(path) && !File.file?(path)
          raise Error, 'terminal output destination is not a regular file'
        end
      end
      inventory
    end
    private_class_method :preflight_outputs

    def validate_output_plan(plan)
      unless plan.is_a?(Hash) && plan.keys.sort == OUTPUTS.sort &&
             plan.values.all? { |bytes| bytes.is_a?(String) && bytes.ascii_only? && bytes.bytesize <= 16 * 1024 * 1024 }
        raise Error, 'terminal publication requires the complete owned output plan'
      end
    end
    private_class_method :validate_output_plan

    def read_input(path, maximum:)
      File.open(path, File::RDONLY | File::NONBLOCK) do |file|
        raise Error, 'terminal input is not a bounded regular file' unless file.stat.file? && file.size <= maximum
        bytes = file.read(maximum + 1) || ''.b
        raise Error, 'terminal input exceeds byte bound' if bytes.bytesize > maximum
        bytes
      end
    end
    private_class_method :read_input
  end
end
