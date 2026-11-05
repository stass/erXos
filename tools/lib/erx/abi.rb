# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'abi_model'
require_relative 'abi_emit_c'
require_relative 'abi_emit_reader'
require_relative 'abi_emit_ruby'
require_relative 'abi_emit_calls'
require_relative 'abi_emit_support'
require_relative 'abi_emit_erlang'
require_relative 'abi_emit_protocol'
require_relative 'json_input'
require_relative 'output_directory'

module Erx
  module ABI
    OutputPlan = Struct.new(:schema, :files, :inventory, keyword_init: true)

    module Generator
      INVENTORY = 'abi/generated.json'
      MAX_INVENTORY_BYTES = 8 * 1024 * 1024
      OWNED = ['include/erx/abi*.h', 'liberx/generated/abi*.c',
               'liberx/generated/calls.h', 'kernel/generated/abi*', 'kernel/generated/*_impl.h',
               'liberx/backend/erx/arch/*/generated/*',
               'liberx/backend/fiasco/generated/*', 'liberx/backend/hosted/generated/*',
               'tools/generated/abi*', 'erlang/apps/erx/include/generated/*',
               'erlang/apps/erx/src/generated/*',
               'docs/generated/abi-reference.md', 'fuzz/generated/abi*'].freeze
      module_function

      def plan(root:, architecture: 'aarch64')
        root = File.expand_path(root)
        source = Sources.read(root: root, architecture: architecture)
        schema = Model.validate(source)
        files = {
          'include/erx/abi.h' => CEmitter.header(schema),
          'include/erx/abi_reader.h' => CEmitter.reader_header(schema),
          'liberx/generated/abi_reader.c' => CEmitter.prefix_source(schema) + CReaderEmitter.source(schema),
          'liberx/generated/calls.h' => CEmitter.call_header(schema),
          'tools/generated/abi.rb' => RubyEmitter.new(schema).emit,
          'docs/generated/abi-reference.md' => SupportEmitter.reference(schema),
          'fuzz/generated/abi.c' => SupportEmitter.fuzz(schema)
        }
        files.merge!(CEmitter.private_headers(schema))
        # Here and not in CallEmitter.outputs, whose marshalling fixture declares no crash types.
        files['include/erx/core/abi_crash.h'] = CallEmitter.crash_seam(schema)
        files.merge!(CallEmitter.outputs(schema))
        files.merge!(ErlangEmitter.outputs(schema))
        files.merge!(ProtocolEmitter.outputs(schema))
        files.each do |path, bytes|
          raise SchemaError, "generated output is not ASCII: #{path}" unless bytes.ascii_only?
        end
        generators = Dir.glob(File.join(root, 'tools/lib/erx/abi*.rb')) +
                     [File.join(root, 'tools/gen_abi.rb')]
        code_inputs = generators.sort.to_h do |path|
          relative = Pathname.new(path).relative_path_from(Pathname.new(File.expand_path(root))).to_s
          [relative, Digest::SHA256.file(path).hexdigest]
        end
        source_inputs = source.inputs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
        inventory = {
          'version' => 1,
          'architecture' => architecture,
          'inputs' => source_inputs.merge(code_inputs).sort.to_h,
          'outputs' => (files.keys + [INVENTORY]).sort,
          'owned_globs' => OWNED
        }
        files[INVENTORY] = JSON.pretty_generate(inventory) + "\n"
        raise SchemaError, 'generated inventory exceeds its byte bound' if files.fetch(INVENTORY).bytesize > MAX_INVENTORY_BYTES
        result = OutputPlan.new(schema: schema, files: files.sort.to_h.freeze,
                                inventory: inventory.freeze).freeze
        Model.freeze_value(result)
      end

      # The complete destination plan is checked before the first write. Every
      # replacement is atomic for that file; an interrupted multi-file publish
      # remains detectable by the inventory's path and byte comparison.
      def publish(plan, root:)
        root = File.realpath(root)
        destinations = plan.files.keys.to_h { |path| [path, destination(root, path)] }
        destinations.each do |path, absolute|
          OutputDirectory.prepare(root: root, path: File.dirname(absolute))
          temporary = "#{absolute}.tmp-#{Process.pid}"
          created = false
          begin
            File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
              created = true
              file.binmode
              file.write(plan.files.fetch(path))
              file.flush
              file.fsync
            end
            File.rename(temporary, absolute)
          ensure
            File.unlink(temporary) if created && File.file?(temporary) && !File.symlink?(temporary)
          end
        end
        plan.files.keys
      rescue SchemaError
        raise
      rescue Error, Errno::EACCES, Errno::ENOENT, Errno::EEXIST, Errno::ENOTDIR,
             Errno::EISDIR, Errno::ENOSPC, Errno::EROFS, Errno::ENAMETOOLONG => error
        raise SchemaError, "cannot publish generated ABI: #{error.message}"
      end

      def check(plan, root:)
        root = File.realpath(root)
        failures = []
        plan.files.each do |path, expected|
          absolute = destination(root, path)
          if !File.file?(absolute)
            failures << "missing #{path}"
          elsif File.binread(absolute) != expected
            failures << "stale #{path}"
          end
        end
        actual = OWNED.flat_map { |pattern| Dir.glob(File.join(root, pattern), File::FNM_DOTMATCH) }
                      .reject { |path| ['.', '..'].include?(File.basename(path)) }
                      .map { |path| path.delete_prefix(root + File::SEPARATOR) }
        old_inventory = File.join(root, INVENTORY)
        if File.file?(old_inventory)
          begin
            document = JsonInput.parse(File.binread(old_inventory, MAX_INVENTORY_BYTES + 1),
                                       max_bytes: MAX_INVENTORY_BYTES, label: 'generated ABI inventory')
            raise SchemaError, 'generated inventory must be an object' unless document.is_a?(Hash)
            outputs = document.fetch('outputs')
            raise SchemaError, 'generated inventory outputs must be paths' unless outputs.is_a?(Array) && outputs.all? { |path| path.is_a?(String) }
            outputs.each { |path| destination(root, path) }
            actual.concat(outputs)
          rescue Erx::Error, KeyError => error
            failures << "invalid inventory: #{error.message}"
          end
        end
        (actual.uniq - plan.files.keys).sort.each { |path| failures << "orphan #{path}" }
        raise SchemaError, failures.join("\n") unless failures.empty?
        true
      end

      def destination(root, path)
        unless path.is_a?(String) && path.ascii_only? && path.match?(/\A[A-Za-z0-9_.\/-]+\z/)
          raise SchemaError, 'invalid generated output path'
        end
        components = path.split('/', -1)
        if path.start_with?('/') || components.any? { |part| ['', '.', '..'].include?(part) || part.bytesize > 255 }
          raise SchemaError, "invalid generated output path #{path}"
        end
        absolute = File.join(root, path)
        OutputDirectory.check(root: root, path: File.dirname(absolute))
        if File.symlink?(absolute) || (File.exist?(absolute) && !File.file?(absolute))
          raise SchemaError, "generated output has an invalid path component: #{path}"
        end
        absolute
      rescue Error => error
        raise if error.is_a?(SchemaError)
        raise SchemaError, "invalid generated output parent: #{error.message}"
      end
    end
  end
end
