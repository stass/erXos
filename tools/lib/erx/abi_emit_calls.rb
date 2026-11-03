# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_c'

module Erx
  module ABI
    # Emits the kernel's call shapes, decoder and result stores, and liberx's
    # per-backend call wrappers, from the validated call declarations.
    #
    # A UTCB parameter owns whole message words. Byte OFFSET of those words is
    # byte OFFSET % 8 of word OFFSET / 8, least significant first, on both
    # sides of the trap, so no side depends on the host's byte order. The
    # kernel loads each word a call reads exactly once into a local copy and
    # decodes only that copy, so user mode rewriting its UTCB meanwhile
    # changes nothing the call decides on.
    module CallEmitter
      # One integer or fixed-bytes field of a parameter, at a byte offset from
      # the start of the parameter's first word, repeated count times.
      Leaf = Struct.new(:type, :offset, :path, :count, :zero_mask, keyword_init: true) do
        def bytes?
          type.is_a?(BytesType)
        end

        def extent
          type.size * (count || 1)
        end
      end

      WORD_HELPERS = [
        '/* Byte OFFSET of a parameter\'s words is byte OFFSET % 8 of word',
        ' * OFFSET / 8, least significant first; a field never crosses a word. */',
        'static inline uint64_t',
        'erx_sys_word_get(const uint64_t *words, size_t offset, unsigned bits)',
        '{',
        "\tuint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;",
        '',
        "\treturn ((words[offset / 8] >> ((offset % 8) * 8)) & mask);",
        '}',
        '',
        'static inline void',
        'erx_sys_word_put(uint64_t *words, size_t offset, unsigned bits, uint64_t value)',
        '{',
        "\tuint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;",
        '',
        "\twords[offset / 8] |= (value & mask) << ((offset % 8) * 8);",
        '}',
        ''
      ].freeze
      module_function

      def outputs(schema)
        return {} if schema.calls.empty?
        %w[ok einval enotsup ewouldblock].each do |status|
          raise SchemaError, "call output requires #{status} status" unless schema.constants.key?(status)
        end
        unless schema.types[Contracts::UTCB_LAYOUT].is_a?(Layout)
          raise SchemaError, "call output requires the #{Contracts::UTCB_LAYOUT} layout"
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
        parameters = CEmitter.call_parameters(call)
        "#{prefix}_#{name}(#{parameters.empty? ? 'void' : parameters.join(', ')})"
      end

      def utcb_parameters(parameters)
        parameters.select { |parameter| parameter.fetch(:location) == 'utcb' }
      end

      def register_parameters(parameters)
        parameters.select { |parameter| parameter.fetch(:location) == 'register' }
      end

      # The first message word and the word count that cover every UTCB
      # parameter of one direction, so a local copy indexes from zero.
      def word_span(parameters)
        utcb = utcb_parameters(parameters)
        return [0, 0] if utcb.empty?
        first = utcb.map { |parameter| parameter.fetch(:slot) }.min
        last = utcb.map { |parameter| parameter.fetch(:slot) + parameter.fetch(:words) }.max
        [first, last - first]
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
          if call.fetch(:executor).fetch(:rule) == 'private'
            word = call.fetch(:executor).fetch(:argument)
            out.concat(["\t/* An executor made the call: the handler refuses it with",
                        "\t * ERX_EWOULDBLOCK unless #{word} lies in the caller's private memory. */",
                        "\tbool\texecutor;"])
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
                    '/* Registers are a private trap snapshot, never a user mapping. The',
                    ' * UTCB is the caller\'s, through the kernel\'s own mapping; user mode may',
                    ' * rewrite it meanwhile, so each word a call reads is loaded once. */',
                    'erx_status_t erx_sys_decode_shape(uint64_t number,',
                    '    const uint64_t registers[6], const erx_utcb_t *utcb, bool executor,',
                    '    erx_sys_shape_t *result);', ''])
        schema.calls.each do |name, call|
          next if call.fetch(:results).empty?
          out.concat(["/* Store #{name}'s results in both result registers and the UTCB. */",
                      "erx_status_t erx_sys_#{name}_store(const erx_sys_#{name}_results_t *results,",
                      '    uint64_t registers[2], erx_utcb_t *utcb);', ''])
        end
        if schema.calls.values.any? { |call| call.fetch(:retry) }
          out.concat(['/* What a handler asks of the dispatch besides its status. Only the',
                      ' * handler of a call declared with retry receives one, so no other',
                      ' * handler can ask for RETRY, and RETRY never reaches a result',
                      ' * register: the dispatch runs the call again from its capability',
                      ' * lookup with the same arguments. */',
                      'typedef enum erx_sys_action {',
                      "\tERX_SYS_ACTION_DONE,",
                      "\tERX_SYS_ACTION_RETRY",
                      '} erx_sys_action_t;', ''])
        end
        out.concat(['/* Only the kernel admission funnel creates this opaque context. */',
                    'typedef struct erx_sys_context erx_sys_context_t;'])
        schema.calls.each do |name, call|
          parameters = ["const #{argument_type(name)} *arguments"]
          parameters << "erx_sys_#{name}_results_t *results" unless call.fetch(:results).empty?
          parameters << 'erx_sys_action_t *action' if call.fetch(:retry)
          out << "erx_status_t erx_sys_#{name}(erx_sys_context_t *context,"
          out << "    #{parameters.join(', ')});"
        end
        out.concat(['', '#endif /* ERX_KERNEL_ABI_CALLS_H */', ''])
        out.join("\n")
      end

      def decoder(schema)
        calls = schema.calls.values
        utcb_used = calls.any? { |call| utcb_parameters(call.fetch(:arguments)).any? }
        executor_used = calls.any? { |call| call.fetch(:executor).fetch(:rule) != 'allow' }
        utcb_results = calls.any? { |call| utcb_parameters(call.fetch(:results)).any? }
        span = calls.map { |call| word_span(call.fetch(:arguments)).last }.max
        out = [CEmitter::NOTICE, '#include "abi_calls.h"', '#include "erx/cdefs.h"', '']
        out.concat(WORD_HELPERS) if utcb_used || utcb_results
        out.concat(decode_function(schema, utcb_used: utcb_used, executor_used: executor_used,
                                           raw_local: integer_leaves?(calls, :arguments), span: span))
        schema.calls.each do |name, call|
          out.concat(store_function(name, call)) unless call.fetch(:results).empty?
        end
        out.join("\n")
      end

      # Whether a UTCB parameter of the given direction has an integer leaf,
      # which needs the generated function's raw-word local.
      def integer_leaves?(calls, direction)
        calls.any? do |call|
          utcb_parameters(call.fetch(direction)).any? do |parameter|
            leaves(parameter.fetch(:type), '').any? { |leaf| !leaf.bytes? }
          end
        end
      end

      def decode_function(schema, utcb_used:, executor_used:, raw_local:, span:)
        utcb = utcb_used ? 'utcb' : 'utcb ERX_UNUSED'
        executor = executor_used ? 'executor' : 'executor ERX_UNUSED'
        out = ['erx_status_t', 'erx_sys_decode_shape(uint64_t number, const uint64_t registers[6],',
               "    const erx_utcb_t *#{utcb}, bool #{executor},",
               '    erx_sys_shape_t *result)', '{', "\terx_sys_shape_t shape = {0};"]
        out << "\tuint64_t words[#{span}] = {0};" if utcb_used
        out << "\tuint64_t raw;" if raw_local
        out.concat(['', "\tif (registers == NULL || result == NULL)", "\t\treturn (ERX_EINVAL);",
                    "\tshape.number = number;", "\tswitch (number) {"])
        schema.calls.each do |name, call|
          out << "\tcase ERX_CALL_#{name.upcase}:"
          case call.fetch(:executor).fetch(:rule)
          when 'refuse' then out.concat(["\t\tif (executor)", "\t\t\treturn (ERX_EWOULDBLOCK);"])
          when 'private' then out << "\t\tshape.arguments.#{name}.executor = executor;"
          end
          register_parameters(call.fetch(:arguments)).each do |argument|
            out.concat(decode_register(name, argument))
          end
          out.concat(decode_utcb(name, call.fetch(:arguments)))
          out << "\t\tbreak;"
        end
        out.concat(["\tdefault:", "\t\treturn (ERX_ENOTSUP);", "\t}",
                    "\t*result = shape;", "\treturn (ERX_OK);", '}', ''])
      end

      def decode_register(name, argument)
        type = argument.fetch(:type)
        base = type.integer
        raw = "registers[#{argument.fetch(:slot)}]"
        out = []
        if base.bits < 64
          out.concat(["\t\tif (#{raw} > UINT64_C(#{(1 << base.bits) - 1}))", "\t\t\treturn (ERX_EINVAL);"])
        end
        value = base.signed ? CEmitter.signed_expression(raw, base) : "(#{CEmitter.c_type(base)})#{raw}"
        target = "shape.arguments.#{name}.#{argument.fetch(:name)}"
        target += '.raw' if type.strong?
        out << "\t\t#{target} = #{value};"
        out.concat(reject_unless_valid(target, type, indent: "\t\t"))
      end

      # The declared range, alignment, enumeration or flag mask of a decoded
      # integer; a failure returns ERX_EINVAL with nothing stored.
      def reject_unless_valid(target, type, indent:)
        base = type.integer
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
        return [] if constraints.empty?
        ["#{indent}if (#{constraints.join(' || ')})", "#{indent}\treturn (ERX_EINVAL);"]
      end

      # Copy every word the call's UTCB arguments own, once, then decode each
      # argument from the copy. A byte of an owned word that no field covers
      # must be zero, as an undefined bit of a register argument must.
      def decode_utcb(name, arguments)
        utcb = utcb_parameters(arguments)
        return [] if utcb.empty?
        first, = word_span(arguments)
        out = ["\t\tif (utcb == NULL)", "\t\t\treturn (ERX_EINVAL);"]
        utcb.each do |argument|
          out.concat(word_loop(argument, first) do |word, index|
            ["\t\t\tif (!erx_utcb_mr_load(utcb, #{word}, &words[#{index}]))", "\t\t\t\treturn (ERX_EINVAL);"]
          end)
        end
        utcb.each do |argument|
          base = (argument.fetch(:slot) - first) * 8
          leaves = leaves(argument.fetch(:type), "shape.arguments.#{name}.#{argument.fetch(:name)}")
          out << utcb_comment(argument, indent: "\t\t")
          out.concat(uncovered_checks(leaves, argument, base))
          leaves.each { |leaf| out.concat(decode_leaf(leaf, base, check: true, indent: "\t\t")) }
        end
        out
      end

      # Visit each message word a parameter owns: the block receives the
      # word's index in the UTCB and in the local copy, and writes the body
      # one level deeper than indent.
      def word_loop(parameter, first, indent: "\t\t")
        count = parameter.fetch(:words)
        start = parameter.fetch(:slot)
        return yield(start.to_s, (start - first).to_s).map { |line| line.delete_prefix("\t") } if count == 1
        local = start == first ? 'index' : "#{start - first} + index"
        ["#{indent}for (size_t index = 0; index < #{count}; index++) {",
         *yield("#{start} + index", local), "#{indent}}"]
      end

      # The C expression of an integer widened to a register or word, by way
      # of its own unsigned width so a signed value never sign-extends.
      def word_cast(source, bits)
        bits == 64 ? "(uint64_t)#{source}" : "(uint64_t)(uint#{bits}_t)#{source}"
      end

      def utcb_comment(parameter, indent:)
        first = parameter.fetch(:slot)
        last = first + parameter.fetch(:words) - 1
        words = first == last ? "mr[#{first}]" : "mr[#{first}] to mr[#{last}]"
        "#{indent}/* #{parameter.fetch(:name)}: #{parameter.fetch(:type).name} in #{words} */"
      end

      def uncovered_checks(leaves, parameter, base)
        covered = Array.new(parameter.fetch(:words) * 8, false)
        leaves.each { |leaf| leaf.extent.times { |byte| covered[leaf.offset + byte] = true } }
        covered.each_slice(8).with_index.filter_map do |bytes, word|
          mask = bytes.each_with_index.sum { |used, byte| used ? 0 : 0xff << (byte * 8) }
          next if mask.zero?
          ["\t\tif ((words[#{base / 8 + word}] & UINT64_C(0x#{mask.to_s(16)})) != 0)",
           "\t\t\treturn (ERX_EINVAL);"]
        end.flatten
      end

      # Flatten a parameter's type to its integer and fixed-bytes leaves. An
      # array of records is unrolled, since the message words bound its size.
      def leaves(type, path, offset = 0, member: ".")
        case type
        when Layout
          type.fields.flat_map do |field|
            if field.array? && field.type.is_a?(Layout)
              field.count.times.flat_map do |element|
                leaves(field.type, "#{path}#{member}#{field.name}[#{element}]",
                       offset + field.offset + element * field.type.size)
              end
            elsif field.type.is_a?(Layout)
              leaves(field.type, "#{path}#{member}#{field.name}", offset + field.offset)
            else
              [leaf(field.type, offset + field.offset, "#{path}#{member}#{field.name}",
                    count: field.count, zero_mask: field.zero_mask)]
            end
          end
        else
          [leaf(type, offset, path, count: nil, zero_mask: 0)]
        end
      end

      def leaf(type, offset, path, count:, zero_mask:)
        unless type.is_a?(BytesType) || (offset % type.size).zero?
          raise SchemaError, "UTCB field #{path} is not naturally aligned"
        end
        Leaf.new(type: type, offset: offset, path: path, count: count, zero_mask: zero_mask).freeze
      end

      # The C lvalue of one element of a leaf and its byte offset expression.
      def leaf_access(leaf, base)
        offset = base + leaf.offset
        return [leaf.path, offset.to_s] unless leaf.count
        ["#{leaf.path}[index]", "#{offset} + index * #{leaf.type.size}"]
      end

      def element_loop(leaf, body, indent:)
        return body.map { |line| "#{indent}#{line}" } unless leaf.count
        ["#{indent}for (size_t index = 0; index < #{leaf.count}; index++) {",
         *body.map { |line| "#{indent}\t#{line}" }, "#{indent}}"]
      end

      def decode_leaf(leaf, base, check:, indent:)
        target, offset = leaf_access(leaf, base)
        body = if leaf.bytes?
                 decode_bytes(leaf, target, offset, check: check)
               else
                 decode_integer(leaf, target, offset, check: check)
               end
        element_loop(leaf, body, indent: indent)
      end

      def decode_bytes(leaf, target, offset, check:)
        out = ["for (size_t byte = 0; byte < #{leaf.type.size}; byte++) {",
               "\t#{target}[byte] = (uint8_t)erx_sys_word_get(words, #{offset} + byte, 8);"]
        out.concat(["\tif (#{target}[byte] != 0)", "\t\treturn (ERX_EINVAL);"]) if check && !leaf.zero_mask.zero?
        out << '}'
      end

      def decode_integer(leaf, target, offset, check:)
        type = leaf.type
        base = type.integer
        target += '.raw' if type.strong?
        value = base.signed ? CEmitter.signed_expression('raw', base) : "(#{CEmitter.c_type(base)})raw"
        out = ["raw = erx_sys_word_get(words, #{offset}, #{base.bits});", "#{target} = #{value};"]
        return out unless check
        unless leaf.zero_mask.zero?
          out.concat(["if ((raw & UINT64_C(#{leaf.zero_mask})) != 0)", "\treturn (ERX_EINVAL);"])
        end
        out + reject_unless_valid(target, type, indent: '')
      end

      def encode_leaf(leaf, base, indent: "\t")
        source, offset = leaf_access(leaf, base)
        body = if leaf.bytes?
                 ["for (size_t byte = 0; byte < #{leaf.type.size}; byte++)",
                  "\terx_sys_word_put(words, #{offset} + byte, 8, #{source}[byte]);"]
               else
                 base_type = leaf.type.integer
                 source += '.raw' if leaf.type.strong?
                 ["erx_sys_word_put(words, #{offset}, #{base_type.bits}, #{word_cast(source, base_type.bits)});"]
               end
        element_loop(leaf, body, indent: indent)
      end

      # The kernel's store of one call's results. Register results go to the
      # result registers after status, and a register no result names is
      # zeroed, so no kernel value reaches user mode through it; each UTCB
      # result's words are built in a local copy and each stored once.
      def store_function(name, call)
        results = call.fetch(:results)
        utcb = utcb_parameters(results)
        first, span = word_span(results)
        out = ['erx_status_t', "erx_sys_#{name}_store(const erx_sys_#{name}_results_t *results,",
               "    uint64_t registers[2], erx_utcb_t *#{utcb.empty? ? 'utcb ERX_UNUSED' : 'utcb'})", '{']
        out << "\tuint64_t words[#{span}] = {0};" unless utcb.empty?
        condition = ['results == NULL', 'registers == NULL']
        condition << 'utcb == NULL' unless utcb.empty?
        out.concat(['', "\tif (#{condition.join(' || ')})", "\t\treturn (ERX_EINVAL);"])
        by_slot = register_parameters(results).to_h { |result| [result.fetch(:slot), result] }
        2.times do |slot|
          result = by_slot[slot]
          next out << "\tregisters[#{slot}] = 0;" unless result
          source = "results->#{result.fetch(:name)}"
          source += '.raw' if result.fetch(:type).strong?
          out << "\tregisters[#{slot}] = #{word_cast(source, result.fetch(:type).integer.bits)};"
        end
        utcb.each do |result|
          base = (result.fetch(:slot) - first) * 8
          out << utcb_comment(result, indent: "\t")
          leaves(result.fetch(:type), "results->#{result.fetch(:name)}").each do |leaf|
            out.concat(encode_leaf(leaf, base))
          end
        end
        utcb.each do |result|
          out.concat(word_loop(result, first, indent: "\t") do |word, index|
            ["\t\tif (!erx_utcb_mr_store(utcb, #{word}, words[#{index}]))", "\t\t\treturn (ERX_EINVAL);"]
          end)
        end
        out.concat(["\treturn (ERX_OK);", '}', ''])
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
        if schema.calls.values.any? { |call| (utcb_parameters(call.fetch(:arguments)) + utcb_parameters(call.fetch(:results))).any? }
          out.concat(['/* The calling thread\'s UTCB, which the erx backend provides. */',
                      'erx_utcb_t *erx_utcb_self(void);', ''])
          out.concat(WORD_HELPERS)
        end
        schema.calls.each { |name, call| out.concat(trap_wrapper(name, call, architecture)) }
        out.join("\n")
      end

      def trap_wrapper(name, call, architecture)
        registers = architecture.fetch(:registers)
        number_register = registers.fetch('number').first
        result_registers = registers.fetch('results')
        utcb_arguments = utcb_parameters(call.fetch(:arguments))
        utcb_results = utcb_parameters(call.fetch(:results))
        uses_utcb = !(utcb_arguments.empty? && utcb_results.empty?)
        out = ['erx_status_t', signature(name, call), '{']
        if uses_utcb
          span = [word_span(call.fetch(:arguments)).last, word_span(call.fetch(:results)).last].max
          out.concat(["\terx_utcb_t *utcb;", "\tuint64_t words[#{span}] = {0};"])
          out << "\tuint64_t raw;" if integer_leaves?([call], :results)
        end
        out.concat(["\tuint32_t raw_status;", "\terx_status_t status;", ''])
        pointers = call.fetch(:results).map { |result| "out_#{result.fetch(:name)}" }
        pointers += utcb_arguments.reject { |argument| argument.fetch(:type).respond_to?(:integer) }
                                  .map { |argument| argument.fetch(:name) }
        pointers.each { |pointer| out.concat(["\tif (#{pointer} == NULL)", "\t\treturn (ERX_EINVAL);"]) }
        out.concat(["\tutcb = erx_utcb_self();", "\tif (utcb == NULL)", "\t\treturn (ERX_EINVAL);"]) if uses_utcb
        out.concat(encode_trap_arguments(call.fetch(:arguments)))
        # The register bindings follow every function call, which could
        # clobber them, and hold only until the trap that reads them.
        out << '' unless out.last == ''
        assignments = register_parameters(call.fetch(:arguments)).to_h do |argument|
          value = argument.fetch(:name)
          value += '.raw' if argument.fetch(:type).strong?
          base = argument.fetch(:type).integer
          [registers.fetch('args').fetch(argument.fetch(:slot)), word_cast(value, base.bits)]
        end
        (registers.fetch('args') | result_registers).each do |register|
          out << "\tregister uint64_t #{register} __asm__(\"#{register}\") = #{assignments.fetch(register, '0')};"
        end
        out << "\tregister uint64_t #{number_register} __asm__(\"#{number_register}\") = ERX_CALL_#{name.upcase};"
        constraints = result_registers.map { |register| "\"+r\"(#{register})" }
        inputs = ([number_register] + registers.fetch('args').reject { |register| result_registers.include?(register) }).map { |register| "\"r\"(#{register})" }
        out << "\t__asm__ volatile(\"#{architecture.fetch(:trap)[0]} ##{architecture.fetch(:trap)[1]}\""
        out << "\t    : #{constraints.join(', ')}"
        out << "\t    : #{inputs.join(', ')}"
        out << "\t    : \"memory\");"
        out << "\traw_status = (uint32_t)#{result_registers.first};"
        out << "\tstatus = #{CEmitter.signed_expression('raw_status', Model::BASE_TYPES.fetch('i32'))};"
        unless call.fetch(:results).empty?
          out << "\tif (status != ERX_OK)"
          out << "\t\treturn (status);"
        end
        register_parameters(call.fetch(:results)).each do |result|
          register = result_registers.fetch(result.fetch(:slot) + 1)
          destination = result.fetch(:type).strong? ? "out_#{result.fetch(:name)}->raw" : "*out_#{result.fetch(:name)}"
          base = result.fetch(:type).integer
          raw = "(uint#{base.bits}_t)#{register}"
          value = base.signed ? CEmitter.signed_expression(raw, base) : raw
          out << "\t#{destination} = #{value};"
        end
        out.concat(decode_trap_results(call.fetch(:results)))
        out << "\treturn (status);"
        out.concat(['}', ''])
      end

      # The leaves of a parameter that liberx passes by pointer: a record's
      # fields through ->, anything else through the dereferenced pointer.
      def pointer_leaves(parameter, pointer)
        type = parameter.fetch(:type)
        return leaves(type, pointer, member: '->') if type.is_a?(Layout)
        leaves(type, "(*#{pointer})")
      end

      # liberx writes the UTCB arguments into its own UTCB before the trap.
      def encode_trap_arguments(arguments)
        utcb = utcb_parameters(arguments)
        return [] if utcb.empty?
        first, = word_span(arguments)
        out = []
        utcb.each do |argument|
          name = argument.fetch(:name)
          root = argument.fetch(:type).respond_to?(:integer) ? leaves(argument.fetch(:type), name) : pointer_leaves(argument, name)
          out << utcb_comment(argument, indent: "\t")
          root.each { |leaf| out.concat(encode_leaf(leaf, (argument.fetch(:slot) - first) * 8)) }
        end
        utcb.each do |argument|
          out.concat(word_loop(argument, first, indent: "\t") do |word, index|
            ["\t\tif (!erx_utcb_mr_store(utcb, #{word}, words[#{index}]))", "\t\t\treturn (ERX_EINVAL);"]
          end)
        end
        out
      end

      # liberx reads the UTCB results the kernel stored, each word once.
      def decode_trap_results(results)
        utcb = utcb_parameters(results)
        return [] if utcb.empty?
        first, = word_span(results)
        out = []
        utcb.each do |result|
          out.concat(word_loop(result, first, indent: "\t") do |word, index|
            ["\t\tif (!erx_utcb_mr_load(utcb, #{word}, &words[#{index}]))", "\t\t\treturn (ERX_EINVAL);"]
          end)
        end
        utcb.each do |result|
          out << utcb_comment(result, indent: "\t")
          pointer_leaves(result, "out_#{result.fetch(:name)}").each do |leaf|
            out.concat(decode_leaf(leaf, (result.fetch(:slot) - first) * 8, check: false, indent: "\t"))
          end
        end
        out
      end
    end
  end
end
