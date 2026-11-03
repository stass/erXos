# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'json_input'
require_relative 'origin'
require_relative 'bounded_file'

module Erx
  module ToolchainProvenance
    module_function

    # An installation directory supplies locations, never trust. Each allowed
    # input and each notice must match the reviewed profile's exact bytes.
    def registry(profile:, installation:)
      document = JsonInput.parse(BoundedFile.read(profile, maximum: 1024 * 1024), max_bytes: 1024 * 1024,
                                 label: 'toolchain provenance')
      keys = %w[version label license status evidence notices files]
      unless document.is_a?(Hash) && document.keys.sort == keys.sort && document['version'] == 1
        raise Error, 'invalid toolchain provenance profile'
      end
      label = document.fetch('label')
      unless label.is_a?(String) && /\A[a-z0-9][a-z0-9.-]{0,127}\z/.match?(label)
        raise Error, 'invalid toolchain provenance label'
      end
      raise Error, 'invalid toolchain license' unless document['license'].is_a?(String)
      Attribution.validate_expression(document.fetch('license'))
      unless %w[permanent stopgap].include?(document['status']) &&
             document['evidence'].is_a?(String) && !document['evidence'].empty? &&
             document['evidence'].ascii_only? && !document['evidence'].match?(/[\x00-\x1f\x7f]/)
        raise Error, 'invalid toolchain provenance attribution'
      end
      root = File.realpath(installation)
      %w[license status evidence].each { |key| document.fetch(key).freeze }
      notices = verified_files(document.fetch('notices'), root: root)
      files = verified_files(document.fetch('files'), root: root)
      files.map do |file|
        relative = file.fetch('path').delete_prefix(root + '/')
        file.merge('label' => "toolchain/#{label}/#{relative}".freeze, 'license' => document.fetch('license'),
                   'status' => document.fetch('status'), 'evidence' => document.fetch('evidence'),
                   'notices' => notices).freeze
      end.freeze
    rescue SystemCallError => error
      raise Error, "cannot read toolchain provenance: #{error.message}"
    end

    def verified_files(entries, root:)
      unless entries.is_a?(Hash) && entries.size.between?(1, 4096)
        raise Error, 'toolchain provenance requires a bounded file inventory'
      end
      entries.sort.map do |relative, hash|
        unless relative.is_a?(String) && relative.ascii_only? && relative.bytesize <= 1024 &&
               relative.split('/').all? { |part| /\A[A-Za-z0-9_.+-]+\z/.match?(part) && !%w[. ..].include?(part) } &&
               !relative.start_with?('/') && hash.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(hash)
          raise Error, 'invalid toolchain provenance file reference'
        end
        path = File.realpath(File.join(root, relative))
        unless path.start_with?(root + '/') &&
               Digest::SHA256.hexdigest(BoundedFile.read(path, maximum: 16 * 1024 * 1024)) == hash
          raise Error, "toolchain provenance mismatch: #{relative}"
        end
        { 'path' => path.freeze, 'sha256' => hash.freeze }.freeze
      end.freeze
    end
    private_class_method :verified_files
  end
end
