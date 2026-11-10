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
    # LLVM's notice from the installation it belongs to (llvm_notices).
    def llvm(root:, resource_dir:)
      resource = File.realpath(resource_dir)
      installation, notice_names = llvm_notices(resource)
      registry(profile: File.join(root, LLVM_PROFILE), installation: installation, files_root: resource,
               notice_names: notice_names)
    rescue SystemCallError => error
      raise Error, "cannot find clang's resource directory: #{error.message}"
    end

    # A FreeBSD port installs LLVM's LICENSE.TXT, byte for byte, under the
    # port's license name LLVM2.
    FREEBSD_PORT_NOTICES = { 'LICENSE.TXT' => 'LLVM2' }.freeze

    # Where the notices of the LLVM whose resource directory is resource are
    # installed, and the name each notice of the profile has there. LLVM's
    # own install tree (an upstream release, Homebrew) keeps LICENSE.TXT at
    # its top, three levels above the resource directory. A FreeBSD port
    # (/usr/local/llvm23) keeps it in its package's license directory
    # instead, /usr/local/share/licenses/llvm23-VERSION, of which there is
    # one per installed port. When neither holds it, the install tree is the
    # answer, and the registry refuses the missing notice there.
    def llvm_notices(resource)
      installation = File.expand_path('../../..', resource)
      return [installation, {}] if File.file?(File.join(installation, 'LICENSE.TXT'))

      port = File.basename(installation)
      licenses = File.join(File.dirname(installation), 'share/licenses')
      package = /\A#{Regexp.escape(port)}-[0-9][0-9A-Za-z._,]*\z/
      found = File.directory?(licenses) ? Dir.children(licenses).grep(package) : []
      found.size == 1 ? [File.join(licenses, found.first), FREEBSD_PORT_NOTICES] : [installation, {}]
    end

    # An installation directory supplies locations, never trust. Each notice
    # is resolved under installation and each file under files_root, and
    # each is recorded with the hash of the bytes installed, so any LLVM
    # release's files are taken as they are. A file is admitted only by the
    # license it declares itself (declares?), since that license decides
    # which notices an image carries. notice_names maps a notice the profile
    # names to the name this installation gives it (llvm_notices).
    def registry(profile:, installation:, files_root: installation, notice_names: {})
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
      notices = verified_files(document.fetch('notices'), root: root, license: nil, names: notice_names)
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

    # entries is a profile's notices or files list, paths relative to root;
    # license is the license each file must declare, or nil for notices;
    # names maps an entry to the name it is installed under, if another.
    def verified_files(entries, root:, license:, names: {})
      unless entries.is_a?(Array) && entries.size.between?(1, 4096) && entries.uniq.size == entries.size
        raise Error, 'toolchain provenance requires a bounded file inventory'
      end
      entries.sort_by(&:to_s).map do |relative|
        unless relative.is_a?(String) && relative.ascii_only? && relative.bytesize <= 1024 &&
               relative.split('/').all? { |part| /\A[A-Za-z0-9_.+-]+\z/.match?(part) && !%w[. ..].include?(part) } &&
               !relative.start_with?('/')
          raise Error, 'invalid toolchain provenance file reference'
        end
        path = File.realpath(File.join(root, names.fetch(relative, relative)))
        raise Error, "toolchain provenance mismatch: #{relative}" unless path.start_with?(root + '/')

        bytes = BoundedFile.read(path, maximum: 16 * 1024 * 1024)
        if license && !declares?(bytes, license)
          raise Error, "toolchain provenance: #{relative} does not declare #{license}"
        end
        { 'path' => path.freeze, 'sha256' => Digest::SHA256.hexdigest(bytes).freeze }.freeze
      end.freeze
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
    private_class_method :llvm_notices, :verified_files, :declares?
  end
end
