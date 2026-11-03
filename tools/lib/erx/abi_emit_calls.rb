# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_c'

module Erx
  module ABI
    module CallEmitter
      module_function

      def outputs(schema)
        return {} if schema.calls.empty?
        %w[ok einval enotsup ewouldblock].each do |status|
          raise SchemaError, "call output requires #{status} status" unless schema.constants.key?(status)
        end
        schema.calls.each_value do |call|
          (call.fetch(:arguments) + call.fetch(:results)).each do |parameter|
            unless parameter.fetch(:location) == 'register' && parameter.fetch(:type).respond_to?(:integer)
              raise SchemaError, 'backend output requires an implemented UTCB aggregate marshalling consumer'
            end
          end
        end
        {
          'kernel/generated/abi_calls.h' => kernel_header(schema),
          'kernel/generated/abi_decode.c' => decoder(schema),
          'liberx/backend/erx/arch/aarch64/generated/calls.c' => trap_source(schema),
          'liberx/backend/fiasco/generated/calls.h' => backend_header(schema, 'fiasco'),
          'liberx/backend/fiasco/generated/calls.c' => backend_source(schema, 'fiasco'),
          'liberx/backend/hosted/generated/calls.h' => backend_header(schema, 'hosted'),
          'liberx/backend/hosted/generated/calls.c' => backend_source(schema, 'hosted')
        }
      end

      def argument_type(name)
        "erx_sys_#{name}_args_t"
      end

      def signature(name, call, prefix: 'erx')
        parameters = call.fetch(:arguments).map { |argument| "#{CEmitter.c_type(argument.fetch(:type))} #{argument.fetch(:name)}" }
        parameters += call.fetch(:results).map { |result| "#{CEmitter.c_type(result.fetch(:type))} *out_#{result.fetch(:name)}" }
        "#{prefix}_#{name}(#{parameters.empty? ? 'void' : parameters.join(', ')})"
      end

      def kernel_header(schema)
        out = [CEmitter::NOTICE, '#ifndef ERX_KERNEL_ABI_CALLS_H', '#define ERX_KERNEL_ABI_CALLS_H', '',
               '#include "erx/abi.h"', '',
               '/* A shape is decoded input, not capability or window authority. */']
        schema.calls.each do |name, call|
          tag = "erx_sys_#{name}_args"
          out.concat(["typedef struct #{tag} #{tag}_t;", "struct #{tag} {"])
          if call.fetch(:arguments).empty?
            out << "\tuint8_t\treserved;"
          else
            call.fetch(:arguments).each do |argument|
              out << "\t#{CEmitter.c_type(argument.fetch(:type))}\t#{argument.fetch(:name)};"
            end
          end
          out.concat(['};', ''])
          unless call.fetch(:results).empty?
            result_tag = "erx_sys_#{name}_results"
            out.concat(["typedef struct #{result_tag} #{result_tag}_t;", "struct #{result_tag} {"])
            call.fetch(:results).each do |result|
              out << "\t#{CEmitter.c_type(result.fetch(:type))}\t#{result.fetch(:name)};"
            end
            out.concat(['};', ''])
          end
        end
        out.concat(['typedef union erx_sys_arguments erx_sys_arguments_t;', 'union erx_sys_arguments {'])
        schema.calls.each_key { |name| out << "\t#{argument_type(name)}\t#{name};" }
        out.concat(['};', '', 'typedef struct erx_sys_shape erx_sys_shape_t;',
                    'struct erx_sys_shape {', "\tuint64_t\t\t number;",
                    "\terx_sys_arguments_t\t arguments;", '};', '',
                    '/* Registers are a private trap snapshot, never a user mapping. */',
                    'erx_status_t erx_sys_decode_shape(uint64_t number,',
                    '    const uint64_t registers[6], bool executor, erx_sys_shape_t *result);', '',
                    '/* Only the kernel admission funnel creates this opaque context. */',
                    'typedef struct erx_sys_context erx_sys_context_t;'])
        schema.calls.each do |name, call|
          out << "erx_status_t erx_sys_#{name}(erx_sys_context_t *context,"
          if call.fetch(:results).empty?
            out << "    const #{argument_type(name)} *arguments);"
          else
            out << "    const #{argument_type(name)} *arguments, erx_sys_#{name}_results_t *results);"
          end
        end
        out.concat(['', '#endif /* ERX_KERNEL_ABI_CALLS_H */', ''])
        out.join("\n")
      end

      def decoder(schema)
        out = [CEmitter::NOTICE, '#include "abi_calls.h"', '',
               'erx_status_t', 'erx_sys_decode_shape(uint64_t number,',
               '    const uint64_t registers[6], bool executor, erx_sys_shape_t *result)', '{',
               "\terx_sys_shape_t shape = {0};", '',
               "\tif (registers == NULL || result == NULL)", "\t\treturn (ERX_EINVAL);",
               "\tshape.number = number;", "\tswitch (number) {"]
        schema.calls.each do |name, call|
          out << "\tcase ERX_CALL_#{name.upcase}:"
          if call.fetch(:properties).fetch('executor') == 'refuse'
            out.concat(["\t\tif (executor)", "\t\t\treturn (ERX_EWOULDBLOCK);"])
          end
          call.fetch(:arguments).each do |argument|
            type = argument.fetch(:type)
            base = type.integer
            raw = "registers[#{argument.fetch(:slot)}]"
            if base.bits < 64
              out.concat(["\t\tif (#{raw} > UINT64_C(#{(1 << base.bits) - 1}))", "\t\t\treturn (ERX_EINVAL);"])
            end
            value = base.signed ? CEmitter.signed_expression(raw, base) : "(#{CEmitter.c_type(base)})#{raw}"
            target = "shape.arguments.#{name}.#{argument.fetch(:name)}"
            target += '.raw' if type.strong?
            out << "\t\t#{target} = #{value};"
            constraints = []
            if type.is_a?(ScalarType)
              constraints << "#{target} < #{CEmitter.literal(type.minimum, base)}" unless type.minimum == base.minimum
              constraints << "#{target} > #{CEmitter.literal(type.maximum, base)}" unless type.maximum == base.maximum
              constraints << "#{target} % #{type.multiple} != 0" unless type.multiple == 1
            elsif type.is_a?(EnumType)
              constraints << if type.allowed
                               type.allowed.map { |item| "#{target} != #{CEmitter.literal(item, base)}" }.join(' && ')
                             elsif type.flags
                               "((uint64_t)#{target} & UINT64_C(#{base.maximum ^ type.mask})) != 0"
                             else
                               type.members.values.map { |item| "#{target} != #{CEmitter.literal(item, base)}" }.join(' && ')
                             end
            end
            unless constraints.empty?
              out.concat(["\t\tif (#{constraints.join(' || ')})", "\t\t\treturn (ERX_EINVAL);"])
            end
          end
          out << "\t\tbreak;"
        end
        out.concat(["\tdefault:", "\t\treturn (ERX_ENOTSUP);", "\t}",
                    "\t*result = shape;", "\treturn (ERX_OK);", '}', ''])
        unless schema.calls.values.any? { |call| call.fetch(:properties).fetch('executor') == 'refuse' }
          out = out.map { |line| line.sub('bool executor, erx_sys_shape_t *result)', 'bool executor ERX_UNUSED, erx_sys_shape_t *result)') }
          out.insert(2, '#include "erx/cdefs.h"')
        end
        out.join("\n")
      end

      def backend_header(schema, backend)
        guard = "ERX_#{backend.upcase}_ABI_CALLS_H"
        out = [CEmitter::NOTICE, "#ifndef #{guard}", "#define #{guard}", '', '#include "erx/abi.h"', '']
        schema.calls.each { |name, call| out << "erx_status_t #{signature(name, call, prefix: "erx_#{backend}")};" }
        (out + ['', "#endif /* #{guard} */", '']).join("\n")
      end

      def backend_source(schema, backend)
        out = [CEmitter::NOTICE, '#include "calls.h"', '#include "liberx/generated/calls.h"', '']
        schema.calls.each do |name, call|
          parameters = call.fetch(:arguments).map { |argument| argument.fetch(:name) }
          parameters += call.fetch(:results).map { |result| "out_#{result.fetch(:name)}" }
          out.concat(['erx_status_t', signature(name, call), '{',
                      "\treturn (erx_#{backend}_#{name}(#{parameters.join(', ')}));", '}', ''])
        end
        out.join("\n")
      end

      def trap_source(schema)
        architecture = schema.architecture || raise(SchemaError, 'trap output needs an architecture')
        out = [CEmitter::NOTICE, '#include "liberx/generated/calls.h"', '']
        registers = architecture.fetch(:registers)
        number_register = registers.fetch('number').first
        schema.calls.each do |name, call|
          out.concat(['erx_status_t', signature(name, call), '{'])
          assignments = call.fetch(:arguments).to_h do |argument|
            value = argument.fetch(:name)
            value += '.raw' if argument.fetch(:type).strong?
            base = argument.fetch(:type).integer
            [registers.fetch('args').fetch(argument.fetch(:slot)), "(uint64_t)(uint#{base.bits}_t)#{value}"]
          end
          (registers.fetch('args') | registers.fetch('results')).each do |register|
            out << "\tregister uint64_t #{register} __asm__(\"#{register}\") = #{assignments.fetch(register, '0')};"
          end
          out << "\tregister uint64_t #{number_register} __asm__(\"#{number_register}\") = ERX_CALL_#{name.upcase};"
          out << "\tuint32_t raw_status;"
          out << "\terx_status_t status;"
          out << ''
          call.fetch(:results).each do |result|
            out << "\tif (out_#{result.fetch(:name)} == NULL)"
            out << "\t\treturn (ERX_EINVAL);"
          end
          result_registers = registers.fetch('results')
          constraints = result_registers.map { |register| "\"+r\"(#{register})" }
          inputs = ([number_register] + registers.fetch('args').reject { |register| result_registers.include?(register) }).map { |register| "\"r\"(#{register})" }
          out << "\t__asm__ volatile(\"#{architecture.fetch(:trap)[0]} ##{architecture.fetch(:trap)[1]}\""
          out << "\t    : #{constraints.join(', ')}"
          out << "\t    : #{inputs.join(', ')}"
          out << '\t    : "memory");'.gsub('\\t', "\t")
          out << "\traw_status = (uint32_t)#{result_registers.first};"
          out << "\tstatus = #{CEmitter.signed_expression('raw_status', Model::BASE_TYPES.fetch('i32'))};"
          unless call.fetch(:results).empty?
            out << "\tif (status != ERX_OK)"
            out << "\t\treturn (status);"
          end
          call.fetch(:results).each do |result|
            register = result_registers.fetch(result.fetch(:slot) + 1)
            destination = result.fetch(:type).strong? ? "out_#{result.fetch(:name)}->raw" : "*out_#{result.fetch(:name)}"
            base = result.fetch(:type).integer
            raw = "(uint#{base.bits}_t)#{register}"
            value = base.signed ? CEmitter.signed_expression(raw, base) : raw
            out << "\t#{destination} = #{value};"
          end
          out << "\treturn (status);"
          out.concat(['}', ''])
        end
        out.join("\n")
      end
    end
  end
end
