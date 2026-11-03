# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'pathname'
require_relative 'runner'

module Erx
  module ABI
    class SchemaError < Erx::Error; end

    Token = Struct.new(:value, :quoted, keyword_init: true)
    SourceLine = Struct.new(:path, :number, :indent, :tokens, keyword_init: true) do
      def words
        tokens.map(&:value)
      end

      def fail!(message)
        raise SchemaError, "#{path}:#{number}: #{message}"
      end
    end

    Declaration = Struct.new(:line, :members, keyword_init: true) do
      def kind
        line.words.first
      end

      def args
        line.words.drop(1)
      end

      def fail!(message)
        line.fail!(message)
      end
    end

    # Lexing retains quotedness so an identifier cannot enter through a string
    # escape. The parser owns its results; consumers receive frozen values.
    module Syntax
      MAX_FILE_BYTES = 16 * 1024 * 1024
      MAX_LINE_BYTES = 8192
      IDENTIFIER = /\A[a-z][a-z0-9_]{0,62}(?:\.[a-z][a-z0-9_]{0,62})*\z/.freeze
      INTEGER = /\A-?(?:0|[1-9][0-9]*|0x[0-9a-fA-F]+)\z/.freeze

      module_function

      def parse(text, path: '<memory>')
        raise SchemaError, "#{path}: source exceeds #{MAX_FILE_BYTES} bytes" if text.bytesize > MAX_FILE_BYTES
        raise SchemaError, "#{path}: source is not ASCII" unless text.ascii_only?
        declarations = []
        current = nil
        previous_indent = 0
        display_path = path.dup.freeze

        text.each_line.with_index(1) do |raw_line, number|
          if raw_line.bytesize > MAX_LINE_BYTES || raw_line.include?("\r") || raw_line.include?("\t")
            raise SchemaError, "#{path}:#{number}: invalid line length, tab or carriage return"
          end
          body = raw_line.delete_suffix("\n")
          indent = body[/\A */].size
          tokens = tokenize(body.byteslice(indent..-1), path: path, number: number)
          next if tokens.empty?
          line = SourceLine.new(path: display_path, number: number,
                                indent: indent, tokens: tokens).freeze
          line.fail!('indentation must be zero, two or four spaces') unless [0, 2, 4].include?(indent)
          line.fail!('a keyword cannot be quoted') if tokens.first.quoted
          if indent.zero?
            current = { line: line, members: [] }
            declarations << current
          else
            line.fail!('member has no declaration') unless current
            line.fail!('nested member has no parent') if indent == 4 && previous_indent.zero?
            current.fetch(:members) << line
          end
          previous_indent = indent
        end

        declarations.map do |entry|
          Declaration.new(line: entry.fetch(:line), members: entry.fetch(:members).freeze).freeze
        end.freeze
      end

      def tokenize(text, path:, number:)
        tokens = []
        cursor = 0
        while cursor < text.bytesize
          byte = text.getbyte(cursor)
          if byte == 32
            cursor += 1
            next
          end
          break if byte == 35
          if byte == 34
            value, cursor = quoted_token(text, cursor + 1, path: path, number: number)
            tokens << Token.new(value: value.freeze, quoted: true).freeze
            if cursor < text.bytesize && ![32, 35].include?(text.getbyte(cursor))
              raise SchemaError, "#{path}:#{number}: missing space after quoted string"
            end
          else
            beginning = cursor
            cursor += 1 while cursor < text.bytesize && ![32, 35].include?(text.getbyte(cursor))
            value = text.byteslice(beginning, cursor - beginning)
            unless value.bytes.all? { |item| item.between?(33, 126) && item != 34 }
              raise SchemaError, "#{path}:#{number}: invalid unquoted token"
            end
            tokens << Token.new(value: value.freeze, quoted: false).freeze
          end
        end
        tokens.freeze
      end

      def quoted_token(text, cursor, path:, number:)
        value = +''.b
        while cursor < text.bytesize
          byte = text.getbyte(cursor)
          cursor += 1
          return [value, cursor] if byte == 34
          if byte == 92
            escape = text.getbyte(cursor)
            cursor += 1
            case escape
            when 34, 92
              value << escape
            when 120
              digits = text.byteslice(cursor, 2)
              unless digits && digits.match?(/\A[0-9a-fA-F]{2}\z/)
                raise SchemaError, "#{path}:#{number}: invalid hexadecimal escape"
              end
              decoded = digits.to_i(16)
              raise SchemaError, "#{path}:#{number}: quoted source string is not ASCII" if decoded > 127
              value << decoded
              cursor += 2
            else
              raise SchemaError, "#{path}:#{number}: unsupported string escape"
            end
          elsif byte.between?(32, 126)
            value << byte
          else
            raise SchemaError, "#{path}:#{number}: control character in quoted string"
          end
        end
        raise SchemaError, "#{path}:#{number}: unterminated quoted string"
      end

      def identifier(value, line:)
        unless value && value.bytesize <= 255 && value.match?(IDENTIFIER)
          line.fail!("invalid identifier #{value.inspect}")
        end
        value.freeze
      end

      def integer(value, line:)
        unless value && value.bytesize <= 22 && value.match?(INTEGER)
          line.fail!("invalid integer #{value.inspect}")
        end
        negative = value.start_with?('-')
        digits = negative ? value.byteslice(1..-1) : value
        number = Integer(digits, digits.start_with?('0x') ? 16 : 10)
        negative ? -number : number
      end
    end

    SourceSet = Struct.new(:declarations, :inputs, keyword_init: true)

    # Includes are an effect at this boundary, not an instruction interpreted
    # by emitters. Real-path identity catches aliases as well as include cycles.
    module Sources
      MAX_INPUT_BYTES = 64 * 1024 * 1024
      MAX_FILES = 1024
      MAX_DEPTH = 64

      module_function

      def read(root:, architecture: 'aarch64')
        root = File.realpath(root)
        abi_root = File.realpath(File.join(root, 'abi'))
        roots = ['abi/erx_abi.txt']
        roots << "abi/arch/#{architecture}.txt" if architecture
        if architecture && !architecture.match?(/\A[a-z][a-z0-9_]*\z/)
          raise SchemaError, 'invalid architecture name'
        end
        pending = roots.reverse.map { |path| [path, 1] }
        seen = {}
        inputs = {}
        declarations = []
        total_bytes = 0

        until pending.empty?
          relative, depth = pending.pop
          raise SchemaError, 'include depth exceeds 64' if depth > MAX_DEPTH
          absolute = File.realpath(File.join(root, relative))
          unless absolute.start_with?(abi_root + File::SEPARATOR) && File.file?(absolute)
            raise SchemaError, "#{relative}: source is outside abi/ or is not an ordinary file"
          end
          raise SchemaError, "#{relative}: repeated include or include cycle" if seen.key?(absolute)
          raise SchemaError, 'too many source files' if seen.size >= MAX_FILES
          seen[absolute] = true
          bytes = File.binread(absolute, Syntax::MAX_FILE_BYTES + 1)
          total_bytes += bytes.bytesize
          raise SchemaError, 'resolved sources exceed 64 MiB' if total_bytes > MAX_INPUT_BYTES
          inputs[relative.freeze] = bytes.freeze
          parsed = Syntax.parse(bytes, path: relative)
          includes = parsed.select { |declaration| declaration.kind == 'include' }
          includes.each do |declaration|
            unless declaration.args.size == 1 && declaration.members.empty?
              declaration.fail!('include requires exactly one path and no members')
            end
            path = declaration.args.first
            components = path.split('/', -1)
            if path.empty? || !path.bytes.all? { |byte| byte.between?(32, 126) } ||
               path.start_with?('/') || components.any? { |part| ['', '.', '..'].include?(part) || part.bytesize > 255 }
              declaration.fail!('include path must stay beneath abi/')
            end
          end
          includes.reverse_each do |declaration|
            pending << [File.join(File.dirname(relative), declaration.args.first), depth + 1]
          end
          declarations.concat(parsed.reject { |declaration| declaration.kind == 'include' })
        end

        SourceSet.new(declarations: declarations.freeze,
                      inputs: inputs.sort.to_h.freeze).freeze
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, Errno::ENAMETOOLONG => error
        raise SchemaError, "cannot read ABI source: #{error.message}"
      end
    end
  end
end
