# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'abi_model'
require_relative 'abi_emit_c'
require_relative 'abi_emit_reader'
require_relative 'abi_emit_ruby'
require_relative 'abi_emit_calls'
require_relative 'abi_emit_support'
require_relative 'abi_emit_erlang'
require_relative 'abi_emit_protocol'
require_relative 'abi_emit_wire'
require_relative 'generation_plan'
require_relative 'abi_emit_inspection'
require_relative 'abi_emit_present'
require_relative 'abi_emit_ui'
require_relative 'abi_emit_ui_wire'
require_relative 'abi_emit_ui_wire_ts'
require_relative 'abi_emit_draw'
require_relative 'abi_emit_input'
require_relative 'abi_emit_web'
require_relative 'abi_emit_web_ts'

module Erx
  module ABI
    OutputPlan = Struct.new(:schema, :files, :reads, keyword_init: true)

    module Generator
      module_function

      def plan(root:, architecture: 'aarch64')
        root = File.expand_path(root)
        source = Sources.read(root: root, architecture: architecture)
        schema = Model.validate(source)
        raise SchemaError, 'the ABI root includes no inspection schema' unless schema.inspection
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
        files.merge!(ProfileEmitter.outputs(schema))
        files.merge!(WireEmitter.outputs(schema))
        files.merge!(InspectionEmitter.outputs(schema))
        files.merge!(PresentEmitter.outputs(schema))
        files.merge!(UIEmitter.outputs(schema))
        files.merge!(UIWireEmitter.outputs(schema))
        files.merge!(UIWireTSEmitter.outputs(schema))
        files.merge!(DrawEmitter.outputs(schema))
        files.merge!(InputEmitter.outputs(schema))
        # The protocol hash covers terminal.txt and its Unicode data, which are
        # not ABI sources, so they join the files this plan reads.
        hashed = schema.web ? WebEmitter.hashed_sources(root: root, inputs: source.inputs) : []
        files.merge!(WebEmitter.outputs(schema, sources: hashed))
        files.each do |path, bytes|
          raise SchemaError, "generated output is not ASCII: #{path}" unless bytes.ascii_only?
        end
        result = OutputPlan.new(schema: schema, files: files.sort.to_h.freeze,
                                reads: source.inputs.merge(hashed.to_h).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }).freeze
        Model.freeze_value(result)
      end

      # The plan Erx::Generated publishes into the build tree. Every ABI
      # source is named by an include from the two roots, so the files read
      # are the complete input record and no glob is needed.
      def generation(root:, architecture: 'aarch64')
        result = plan(root: root, architecture: architecture)
        GenerationPlan.new(files: result.files, reads: result.reads)
      end
    end
  end
end
