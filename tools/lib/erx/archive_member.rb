# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'output_directory'

module Erx
  # Both build-record backends read archive members through this boundary.
  # Normal archives contain their bytes; thin archives refer to other files.
  module ArchiveMember
    MAX_BYTES = 64 * 1024 * 1024
    module_function

    # listings keeps member names by program and archive bytes, which decide them, for a
    # caller that asks for many members of one archive.
    def sha256(bytes:, member:, runner:, program:, owner_root:, directory:, name:, environment: nil, listings: {})
      unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES && bytes.start_with?("!<arch>\n".b)
        raise Error, 'source checking requires a self-contained normal archive'
      end
      unless member.is_a?(String) && member.bytesize.between?(1, 1024) && !member.match?(/[\x00-\x20\x7f()\/]/)
        raise Error, 'invalid archive member name'
      end
      raise Error, 'archive checking requires a command runner' unless runner.respond_to?(:run)
      environment ||= ENV.keys.to_h { |key| [key, nil] }.merge('PATH' => ENV.fetch('PATH'),
        'TMPDIR' => File.realpath(Dir.tmpdir), 'LC_ALL' => 'C')
      directory = OutputDirectory.prepare(root: owner_root, path: directory)
      Dir.mktmpdir('.archive-member-', directory) do |temporary|
        snapshot = File.join(temporary, 'input.a')
        File.binwrite(snapshot, bytes)
        names = listings[[program, bytes]] ||= begin
          listing = runner.run([program, 't', '--', snapshot], name: name + '-list', deadline: 30,
            env: environment, output_limit: MAX_BYTES)
          # Reaching the hard cap is a refusal even if a tool ignores a failed
          # write and exits successfully; a partial listing cannot prove uniqueness.
          BoundedFile.read(listing.fetch('log'), maximum: MAX_BYTES - 1).lines.map(&:chomp)
        end
        count = names.count(member)
        raise Error, "ambiguous archive member name: #{member}" if count > 1
        raise Error, "archive member is absent: #{member}" if count.zero?
        result = runner.run([program, 'p', '--', snapshot, member], name: name, deadline: 30,
          env: environment, output_limit: MAX_BYTES)
        Digest::SHA256.hexdigest(BoundedFile.read(result.fetch('log'), maximum: MAX_BYTES - 1))
      end
    end
  end
end
