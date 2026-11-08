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

    LLVM_PROFILE = 'config/provenance/llvm.json'

    # The reviewed LLVM profile's registry: the resource headers an image may
    # include, read from clang's resource directory (resource_dir, which
    # `clang -print-resource-dir` names), whatever LLVM release it is, with
    # LLVM's notice from the installation it belongs to.
    def llvm(root:, resource_dir:)
      resource = File.realpath(resource_dir)
      registry(profile: File.join(root, LLVM_PROFILE), installation: File.expand_path('../../..', resource),
               files_root: resource)
    rescue SystemCallError => error
      raise Error, "cannot find clang's resource directory: #{error.message}"
    end

    # An installation directory supplies locations, never trust. Each notice
    # is resolved under installation and each file under files_root, and
    # each is checked against its profile entry: a SHA-256 pins its exact
    # bytes, and "spdx" admits the file by the license it declares itself
    # (declares?), so a header any LLVM release installs is taken on its own
    # notice and recorded with the bytes it has.
    def registry(profile:, installation:, files_root: installation)
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
      files_root = File.realpath(files_root)
      %w[license status evidence].each { |key| document.fetch(key).freeze }
      notices = verified_files(document.fetch('notices'), root: root, license: nil)
      files = verified_files(document.fetch('files'), root: files_root, license: document.fetch('license'))
      files.map do |file|
        relative = file.fetch('path').delete_prefix(files_root + '/')
        file.merge('label' => "toolchain/#{label}/#{relative}".freeze, 'license' => document.fetch('license'),
                   'status' => document.fetch('status'), 'evidence' => document.fetch('evidence'),
                   'notices' => notices).freeze
      end.freeze
    rescue SystemCallError => error
      raise Error, "cannot read toolchain provenance: #{error.message}"
    end

    # entries is a profile's notices or files map; license is the license
    # an "spdx" entry must declare, or nil where every entry is pinned by
    # its SHA-256, as notices are.
    def verified_files(entries, root:, license:)
      unless entries.is_a?(Hash) && entries.size.between?(1, 4096)
        raise Error, 'toolchain provenance requires a bounded file inventory'
      end
      entries.sort.map do |relative, pin|
        unless relative.is_a?(String) && relative.ascii_only? && relative.bytesize <= 1024 &&
               relative.split('/').all? { |part| /\A[A-Za-z0-9_.+-]+\z/.match?(part) && !%w[. ..].include?(part) } &&
               !relative.start_with?('/') && valid_pin?(pin, license)
          raise Error, 'invalid toolchain provenance file reference'
        end
        path = File.realpath(File.join(root, relative))
        raise Error, "toolchain provenance mismatch: #{relative}" unless path.start_with?(root + '/')

        bytes = BoundedFile.read(path, maximum: 16 * 1024 * 1024)
        found = Digest::SHA256.hexdigest(bytes)
        if pin == 'spdx'
          raise Error, "toolchain provenance: #{relative} does not declare #{license}" unless declares?(bytes, license)
        elsif found != pin
          raise Error, "toolchain provenance mismatch: #{relative}"
        end
        { 'path' => path.freeze, 'sha256' => found.freeze }.freeze
      end.freeze
    end

    # A pin is a file's SHA-256, or "spdx" where license names what the file
    # must declare (verified_files).
    def valid_pin?(pin, license)
      pin.is_a?(String) && ((license && pin == 'spdx') || /\A[0-9a-f]{64}\z/.match?(pin))
    end

    # Whether bytes declare exactly license: the first SPDX-License-Identifier
    # line wholly within SPDX_WINDOW bytes, in the leading comment where LLVM's
    # resource headers carry theirs, names license and nothing more; a later
    # line is not read.
    SPDX_WINDOW = 4096

    def declares?(bytes, license)
      # A line the window cuts off is not a declaration: only whole lines count.
      line = bytes.byteslice(0, SPDX_WINDOW).b.lines.find do |text|
        text.end_with?("\n") && text.include?('SPDX-License-Identifier:')
      end
      declared = line&.match(%r{\A\s*(?:/?\*+|//)?\s*SPDX-License-Identifier:\s*(.*?)\s*(?:\*/)?\s*\z}n)
      !declared.nil? && declared[1] == license.b
    end
    private_class_method :verified_files, :valid_pin?, :declares?
  end
end
