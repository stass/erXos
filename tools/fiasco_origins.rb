#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/erx/origin'
require_relative 'lib/erx/fiasco_parts'
require_relative 'import_origins'

module Erx
  # The Fiasco parts' license review profile and the listing of the notice
  # blocks their inventories (each part's ORIGIN.md) leave unread. Publisher
  # package declarations are package rules, which cover files without a
  # notice of their own; Attribution reads a file's own SPDX line or
  # license notice first.
  module FiascoOrigins
    # The SHA-256 of each part's LICENSE.spdx, whose DataLicense was read.
    LICENSE_SPDX = {
      'bootstrap' => '3c32105532f6401644a9286ae3ab893b86d5ba5772e0938e2f54659c9da48c6f',
      'drivers-frst' => '75e6ac7d0937f58a6009008a4d712a56b9299b0f50e9f83177471980b53b8af1',
      'kernel' => 'e37cecd652b8236b0f13f789e4039d25be28b0d28c04a12f2ad45f0380dcf301',
      'l4re-core' => '551dd862b2d63b5bc6a920d40b02f359c7eaffca84037e01a35232013df30825',
      'libfdt' => 'dd0991471a8a22455c8daa40b679d25fd85576f4e4c39a974c2a209bfd3470c3',
      'mk' => '5b801397513b4b8ae49f154dfe25064116bc25233853ef9c38203f80f49da5e2'
    }.freeze

    # The Fiasco parts, each with its own inventory.
    PARTS = FiascoParts::NAMES

    module_function

    def package_rules(directory)
      declarations = File.read(File.join(directory, 'LICENSE.spdx')).split(/^PackageName: /)
      declarations.each_with_object([]) do |declaration, rules|
        path = declaration[/^PackageFileName: \.\/(.+)$/, 1]
        license = declaration[/^PackageLicenseConcluded: (.+)$/, 1]
        next unless path && license && File.exist?(File.join(directory, path))
        rules << { 'pattern' => "#{path}/**/*", 'license' => license, 'kind' => 'package',
                   'evidence' => "reviewed LICENSE.spdx package declaration for #{path}" }
      end.sort_by { |rule| -rule.fetch('pattern').bytesize }
    end

    def profile(directory, part:)
      corrections = [
        ['GPL-2.0-only or License-Ref-kk-custom', 'GPL-2.0-only'],
        ['GPL-2.0-only OR License-Ref-kk-custom', 'GPL-2.0-only'],
        ['GPL-2.0', 'GPL-2.0-only'],
        ['GPL-2.0+', 'GPL-2.0-or-later'],
        ['GPL-2.0 WITH Linux-syscall-note', 'GPL-2.0-only WITH Linux-syscall-note']
      ].map do |declared, selected|
        { 'pattern' => '**/*', 'declared_license' => declared, 'license' => selected,
          'evidence' => 'reviewed exact header declaration; standard GPL version selected; no custom grant asserted' }
      end
      rules = corrections
      if part == 'l4re-core'
        rules.concat(ImportOrigins.musl_license_rules.map do |rule|
          rule.merge('files' => rule.fetch('files').transform_keys { |path| 'libc/musl/contrib/musl/' + path },
                     'evidence' => "reviewed musl 1.2.5 grant: #{rule.fetch('evidence')}")
        end)
        rules << { 'pattern' => 'libc/musl/**/*', 'license' => 'MIT', 'kind' => 'package',
                   'evidence' => 'reviewed embedded musl COPYRIGHT and original-file MIT grant; specific exceptions precede this rule' }
      end
      rules.concat(package_rules(directory))
      rules.unshift('files' => { 'LICENSE.spdx' => LICENSE_SPDX.fetch(part) }, 'license' => 'CC0-1.0',
                    'evidence' => 'LICENSE.spdx DataLicense: CC0-1.0')
      { 'import' => part, 'default_license' => 'MIT',
        'default_evidence' => 'reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence',
        'rules' => rules }
    end

    # The notice blocks of the inventories' files that the notice table must
    # list before a file can be read as permissive: every block holding a
    # license mark in a file whose license its notice decides, but those
    # read as GNU notices. Each distinct block is one row, as the table holds
    # it, with the files that hold it, one example and the license the table
    # gives it ('-' for none), so a reviewer reads each text once. A file is
    # read from the tree when its bytes are the row's, else from its part's
    # original tree when one is named, else not at all. No text is printed.
    def notices(root:, originals: {})
      project = File.expand_path(root)
      listed = Attribution.listed_notices
      found = PARTS.each_with_object({}) do |part, blocks|
        directory = File.join(project, 'fiasco', part)
        review = Attribution.review(profile(directory, part: part))
        Origin.new(root: directory).inventory.fetch('files').each do |path, row|
          bytes = recorded_bytes([directory, originals[part]].compact.map { |base| File.join(base, path) },
                                 row: row)
          next unless bytes && Attribution.for_file(path, bytes: bytes, sidecar: nil, review: review,
                                                          notices: {}).fetch('license') == Attribution::UNRECOGNIZED_NOTICE

          Attribution.unread_blocks(bytes).each do |block|
            (blocks[Digest::SHA256.hexdigest(block)] ||= []) << "#{part}/#{path}"
          end
        end
      end
      found.sort.map { |sha256, paths| [sha256, paths.size, paths.min, listed[sha256]&.license || '-'].join(' ') }
    end

    # A row's bytes from the first candidate path holding them; nil for a
    # symlink or when none does.
    def recorded_bytes(candidates, row:)
      return nil unless row.fetch('kind') == 'file'

      candidates.each do |candidate|
        next unless File.file?(candidate) && !File.symlink?(candidate)

        bytes = File.binread(candidate)
        return bytes if Digest::SHA256.hexdigest(bytes) == row.fetch('sha256')
      end
      nil
    end
    private_class_method :recorded_bytes
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: File.expand_path('..', __dir__) }
  parser = OptionParser.new do |arguments|
    arguments.banner = 'usage: ruby tools/fiasco_origins.rb --notices [--original PART=DIRECTORY]...'
    arguments.on('--notices', 'list the notice blocks the notice table must review') { options[:notices] = true }
    arguments.on('--original PART=DIRECTORY', 'an unpacked original tree of a part, for its changed files') do |value|
      part, directory = value.split('=', 2)
      raise OptionParser::InvalidArgument, value unless Erx::FiascoOrigins::PARTS.include?(part) && directory

      (options[:originals] ||= {})[part] = File.expand_path(directory)
    end
    arguments.on('--root DIRECTORY') { |value| options[:root] = value }
  end
  begin
    remaining = parser.parse(ARGV)
    raise OptionParser::InvalidArgument, remaining.join(' ') unless remaining.empty?
    raise OptionParser::MissingArgument, '--notices' unless options[:notices]

    Erx::FiascoOrigins.notices(root: options.fetch(:root), originals: options.fetch(:originals, {}))
                      .each { |row| Erx::Terminal.puts(row) }
  rescue OptionParser::ParseError => error
    Erx::Terminal.puts(error.message)
    exit 2
  rescue Erx::Error, SystemCallError, KeyError => error
    Erx::Terminal.puts(error.message)
    exit 1
  end
end
