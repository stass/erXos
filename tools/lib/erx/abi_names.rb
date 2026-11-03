# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ABI
    # One spelling function and one inventory cover declarations and helpers.
    # Emitters use these same names, so validation cannot miss a normalization
    # collision which appears only in a generated language.
    module Names
      C_KEYWORDS = %w[auto break case char const continue default do double
                      else enum extern float for goto if inline int long
                      register restrict return short signed sizeof static
                      struct switch typedef union unsigned void volatile while
                      bool true false alignas alignof atomic_assert
                      class namespace template typename public private protected
                      operator new delete this virtual friend using try catch
                      throw constexpr consteval constinit nullptr].freeze
      module_function

      def stem(value)
        value.delete_prefix('erx_').tr('.', '_')
      end

      def c(value)
        "erx_#{stem(value)}"
      end

      def macro(value)
        "ERX_#{stem(value).upcase}"
      end

      def local(value, line:)
        unless value && value.match?(/\A[a-z][a-z0-9_]{0,62}\z/) && !C_KEYWORDS.include?(value)
          line.fail!("invalid local identifier #{value.inspect}")
        end
        value
      end

      def validate(types:, constants:, calls:, readers:, architecture:, line:)
        symbols = {}
        reserve = lambda do |symbol, origin|
          if symbols.key?(symbol)
            line.fail!("generated symbol #{symbol} collides: #{symbols.fetch(symbol)} and #{origin}")
          end
          symbols[symbol] = origin
        end
        %w[ERX_ABI_H ERX_ABI_HRL ERX_ABI_READER_H ERX_GENERATED_CALLS_H
           ERX_KERNEL_ABI_CALLS_H ERX_FIASCO_ABI_CALLS_H ERX_HOSTED_ABI_CALLS_H
           ERX_UNUSED erx_status_t
           erx_rights erx_rights_t erx_rights_default erx_rights_shrink
           erx_abi_error erx_abi_error_t erx_abi_load_u16 erx_abi_load_u32
           erx_abi_load_u64 erx_abi_fail erx_abi_zero erx_abi_utf8
           erx_abi_identifier erx_abi_path erx_abi_vector
           erx_sys_arguments erx_sys_arguments_t erx_sys_shape erx_sys_shape_t
           erx_sys_context erx_sys_context_t erx_sys_decode_shape].each do |symbol|
          reserve.call(symbol, 'generated interface')
        end
        constants.each_key { |name| reserve.call(macro(name), "constant #{name}") }
        types.each_value do |type|
          next if type.is_a?(IntegerType)
          tag = c(type.name)
          reserve.call("#{tag}_t", "type #{type.name}")
          if type.is_a?(ScalarType) || type.is_a?(Layout)
            reserve.call(tag, "struct #{type.name}")
          end
          if type.is_a?(BytesType) && type.fixed
            reserve.call("#{macro(type.name)}_BYTES", "fixed bytes #{type.name}")
            reserve.call("#{macro(type.name)}_SIZE", "fixed byte size #{type.name}")
            reserve.call("#{macro(type.name)}_STRING", "fixed byte string #{type.name}")
          end
          next unless type.is_a?(Layout)
          reserve.call("#{macro(type.name)}_SIZE", "layout size #{type.name}")
          reserve.call("#{macro(type.name)}_ALIGN", "layout alignment #{type.name}")
          reserve.call("#{tag}_decode", "layout decoder #{type.name}") if type.storage == 'wire_le'
          members = type.fields.map(&:name)
          members += type.padding.each_index.map { |index| "padding_#{index}" }
          members << type.tail.name if type.tail
          line.fail!("generated member collision in #{type.name}") unless members.uniq.size == members.size
          type.fields.each do |field|
            local(field.name, line: field.line)
            reserve.call("#{macro(type.name)}_OFF_#{field.name.upcase}", "field offset #{type.name}.#{field.name}")
            prefix = "#{tag}_#{field.name}"
            field.bits.each do |bits|
              %w[get set].each { |operation| reserve.call("#{prefix}_#{bits.fetch(:name)}_#{operation}", "bit accessor #{type.name}.#{field.name}") }
            end
            if field.atomic
              reserve.call("#{prefix}_load", "atomic load #{type.name}.#{field.name}")
              reserve.call("#{prefix}_store", "atomic store #{type.name}.#{field.name}") unless field.atomic.fetch(:store) == 'none'
            end
          end
          if type.sequence
            field = type.sequence.fetch(:field)
            reserve.call("#{macro(type.name)}_#{field.upcase}_TERMINAL", "sequence terminal #{type.name}")
            reserve.call("#{macro(type.name)}_#{field.upcase}_EXHAUSTION", "sequence exhaustion #{type.name}")
            reserve.call("#{tag}_#{field}_status", "sequence status #{type.name}")
          end
        end
        reserve.call('ERX_DECLARE_ABI_NOTE', 'ABI note declaration') if types.key?('erx_abi_note')
        calls.each do |name, call|
          local(name, line: line)
          %W[erx_#{name} erx_sys_#{name} erx_fiasco_#{name} erx_hosted_#{name}].each { |symbol| reserve.call(symbol, "call #{name}") }
          %W[erx_sys_#{name}_args erx_sys_#{name}_args_t].each do |symbol|
            reserve.call(symbol, "call arguments #{name}")
          end
          unless call.fetch(:results).empty?
            %W[erx_sys_#{name}_results erx_sys_#{name}_results_t].each do |symbol|
              reserve.call(symbol, "call results #{name}")
            end
          end
          parameters = call.fetch(:arguments).map { |argument| argument.fetch(:name) }
          parameters += call.fetch(:results).map { |result| "out_#{result.fetch(:name)}" }
          line.fail!("generated parameter collision in #{name}") unless parameters.uniq.size == parameters.size
          locals = %w[status raw_status] + architecture.fetch(:registers).fetch('args') +
                   architecture.fetch(:registers).fetch('number') + architecture.fetch(:registers).fetch('results')
          unless (parameters & locals).empty?
            line.fail!("call parameter collides with a trap local in #{name}")
          end
        end
        readers.each do |reader|
          prefix = c(reader.name)
          %W[#{prefix}_open #{prefix}_view #{prefix}_view_t].each { |symbol| reserve.call(symbol, "reader #{reader.name}") }
          (['root'] + reader.tables.keys).each do |scope|
            reserve.call("#{prefix}_check_#{scope}", "reader scope #{reader.name}.#{scope}")
          end
          reader.tables.each_key { |table| reserve.call("#{prefix}_#{table}_at", "table accessor #{reader.name}.#{table}") }
        end
        symbols.freeze
      end
    end
  end
end
