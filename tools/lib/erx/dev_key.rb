# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require_relative 'error'
require_relative 'generated_abi'
require_relative 'git_environment'
require_relative 'key_directory'
require_relative 'source_revision'
require_relative 'ssh_hardening'

module Erx
  # The development login key (docs/design-ssh.md, "Login keys"): an Ed25519 pair that
  # OpenSSH's ssh-keygen makes, whose public half a development image carries as root's
  # one login key and whose private half `tools/erx ssh` logs in with. It is a key of its
  # own, never an update-signing key.
  #
  # There is one pair per clone, in DIRECTORY under git's common directory, which every
  # worktree of the clone shares and no commit can hold, so every worktree builds the
  # same image of one commit and the QEMU gate's reuse of passing boots holds across
  # them (QemuReuse). A tree that is not a git checkout is its own clone and keeps the
  # pair in its build tree. The private half is mode 0600 in a mode 0700 directory and
  # never enters an image, a receipt or a log: the image build is handed only the public
  # line, which carries no comment, so no user or host name of the builder rides along.
  #
  # ensure is the one operation that makes the pair, for `tools/erx setup` and the image
  # build alike. It keeps a pair that checks out, refuses one that is damaged or whose
  # halves disagree, and makes a missing one whole or not at all (Erx::KeyDirectory).
  module DevKey
    DIRECTORY = 'erxos/dev-key'
    UNCLONED_DIRECTORY = 'build/dev-key'
    PRIVATE = 'id_ed25519'
    PUBLIC = "#{PRIVATE}.pub".freeze
    # The private file's comment; the image's line has none.
    COMMENT = 'erxos-development'
    CODEC = ABI::Generated::CODEC
    private_constant :CODEC
    TYPE = CODEC.fixed_bytes('ssh_ed25519_name').freeze
    # The wire form of an Ed25519 public key (RFC 8709, section 4): the type and the
    # key, each a string with its 32-bit length, as abi/formats/ssh.txt sizes them. Every
    # blob opens with BLOB_PREFIX, the type and the key's length, and the key follows.
    KEY_BYTES = CODEC.constant('ssh_ed25519_key_size')
    BLOB_PREFIX = ([TYPE.bytesize].pack('N') + TYPE + [KEY_BYTES].pack('N')).freeze
    BLOB_BYTES = BLOB_PREFIX.bytesize + KEY_BYTES
    DEADLINE = 60

    # The pair at directory: the private key's path and the public half as the image
    # carries it, `ssh-ed25519 BASE64`. The directory is a plain path (PLAIN_PATH), checked
    # here once, so every path ssh_argv derives from it is one ssh reads as written.
    Pair = Data.define(:directory, :public_line) do
      def initialize(directory:, public_line:)
        DevKey.plain_path(directory, what: 'the development key directory')
        super
      end

      def private_path = File.join(directory, PRIVATE)
    end
    # The name of a boot's known-hosts file, in the boot's own directory, which starts
    # empty with each boot as the guest's /data does: ssh adds the guest's host key on
    # first use (accept-new) under HOST_KEY_ALIAS and refuses a changed one for the rest
    # of the boot, and no entry of the user's known_hosts for the forwarded loopback port,
    # another guest's or another program's, trips or is tripped by it.
    KNOWN_HOSTS = 'known_hosts'
    HOST_KEY_ALIAS = 'erxos-development'
    # ssh splits a known-hosts path at whitespace and expands ~, % tokens and ${} in it
    # and in an identity file's path (ssh_config(5), UserKnownHostsFile and IdentityFile),
    # so a path is passed only when it is absolute and holds none of those.
    PLAIN_PATH = %r{\A/[[:graph:]&&[^%$~"'\\]]*\z}

    # The port a development guest's daemon listens on, the development manifest's
    # erx_ssh_dev:boot(PORT) for root's session, which a
    # host loopback port forwarded to the guest reaches (docs/design-ssh.md, "Stages").
    PORT = 2222
    # What every ssh of DevKey's runs with: no configuration file, so nothing of the
    # user's ~/.ssh/config applies; only this key is offered, it never enters the user's
    # agent, and nothing is forwarded to the guest (SshHardening); and the guest's host key
    # is checked against the boot's known-hosts file alone (KNOWN_HOSTS).
    SSH_OPTIONS = ['-F', File::NULL, '-o', 'AddKeysToAgent=no', '-o', 'IdentitiesOnly=yes',
                   *SshHardening::OPTIONS, '-o', 'StrictHostKeyChecking=accept-new', '-o', "GlobalKnownHostsFile=#{File::NULL}"].freeze

    module_function

    # The host's ssh to user at the guest whose daemon the host's loopback port port
    # reaches, logging in with pair's key and checking the guest's host key against the
    # boot's known_hosts file under HOST_KEY_ALIAS, with options before the destination
    # and command, when given, after it: one argument, which ssh sends unchanged as the
    # exec request's command and the guest runs with rc -c (docs/design-ssh.md,
    # "Stages"). Without one the guest runs a shell.
    def ssh_argv(pair:, port:, known_hosts:, user: 'root', options: [], command: nil)
      raise Error, 'an ssh port is a port number' unless port.is_a?(Integer) && port.between?(1, 65_535)
      # A name that began with '-' would be read as one of ssh's options.
      raise Error, "#{user.inspect} is not a user name" unless user.is_a?(String) && /\A[a-z_][a-z0-9_-]{0,31}\z/.match?(user)

      # An empty command would ask for a shell, and an array would be several arguments.
      raise Error, 'an ssh command is a non-empty string' unless command.nil? || (command.is_a?(String) && !command.empty?)

      plain_path(known_hosts, what: 'the known-hosts file')
      ['ssh', *SSH_OPTIONS, '-o', "UserKnownHostsFile=#{known_hosts}", '-o', "HostKeyAlias=#{HOST_KEY_ALIAS}",
       '-i', pair.private_path, '-p', port.to_s, *options, '--', "#{user}@127.0.0.1", *command]
    end

    # path, which must be a PLAIN_PATH; what names it in the error.
    def plain_path(path, what:)
      raise Error, "ssh cannot name #{what} #{path.to_s.dump} as written" unless path.is_a?(String) && PLAIN_PATH.match?(path)

      path
    end

    # The clone's key directory for the tree at root: under git's common directory, or
    # under root's build tree when the tree is not a git checkout.
    def directory(root:, runner:)
      return File.join(root, UNCLONED_DIRECTORY) unless File.exist?(File.join(root, '.git'))

      environment = GitEnvironment.isolated
      result = runner.run([*SourceRevision::GIT, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                          name: 'dev-key-git-dir', deadline: DEADLINE, chdir: root, env: environment)
      common = File.binread(result.fetch('log')).chomp
      raise Error, "git's common directory is not an absolute path: #{common.dump}" unless
        common.ascii_only? && common.start_with?('/') && !common.include?("\n")

      File.join(common, DIRECTORY)
    end

    # The pair at directory, made first when there is none there.
    def ensure(directory:, runner:)
      KeyDirectory.ensure(directory, what: 'the development key') do |fresh|
        runner.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', COMMENT, '-f', File.join(fresh, PRIVATE)],
                   name: 'dev-key-make', deadline: DEADLINE)
      end
      read(directory: directory, runner: runner)
    end

    # The pair at directory, which must exist and check out: an owner-only directory
    # holding an owner-only regular private file and a public file of one Ed25519 key that
    # ssh-keygen derives from the private one.
    def read(directory:, runner:)
      KeyDirectory.checked(directory, what: 'the development key')
      private_path = KeyDirectory.private_file(directory, PRIVATE, what: 'the development key')

      public_path = File.join(directory, PUBLIC)
      raise Error, "the development key's public half #{public_path} is missing" unless
        File.file?(public_path) && !File.symlink?(public_path)

      line = public_line(File.binread(public_path, 4096), source: public_path)
      derived = derive(private_path, runner: runner)
      raise Error, "the development key's halves in #{directory} disagree; remove the directory to make a new pair" unless
        derived == line

      Pair.new(directory: directory, public_line: line)
    end

    # `ssh-ed25519 BASE64` of text, an OpenSSH public key line whose key is one Ed25519
    # key in its wire form (BLOB_BYTES); its comment, if any, is dropped.
    def public_line(text, source:)
      type, encoded = text.split(/[ \t]+/, 3)
      blob = encoded.to_s.chomp.unpack1('m0')
      raise Error, "#{source} is not one Ed25519 public key" unless
        type == TYPE && blob.bytesize == BLOB_BYTES && blob.start_with?(BLOB_PREFIX)
      "#{TYPE} #{[blob].pack('m0')}"
    rescue ArgumentError
      raise Error, "#{source} is not one Ed25519 public key"
    end

    # The public line ssh-keygen derives from the private key at path. Only the public
    # line reaches the command's output file.
    def derive(path, runner:)
      output = "#{File.dirname(path)}/.derived-#{Process.pid}-#{SecureRandom.hex(8)}"
      runner.run(['ssh-keygen', '-y', '-f', path], name: 'dev-key-derive', deadline: DEADLINE, stdout: output)
      public_line(File.binread(output, 4096), source: "ssh-keygen -y of #{path}")
    rescue CommandError
      raise Error, "ssh-keygen cannot read the development key #{path}; remove its directory to make a new pair"
    ensure
      FileUtils.rm_f(output) if output
    end
  end
end
