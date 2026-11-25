# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/dev_key'
require_relative '../../tools/lib/erx/pack'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/runner'

# The development login key (docs/design-ssh.md, "Login keys"), made with the host's
# ssh-keygen: DevKey.ensure makes a pair once and keeps it, refuses a damaged pair or one
# whose halves disagree, and leaves no half-made directory; the public line carries no
# comment; ssh_argv reads no configuration file, keeps the key out of the user's agent and
# the guest's host key out of the user's known_hosts, and passes no path ssh would
# rewrite, a pair's directory refused once when the pair is made; and Pack refuses the
# key's file in any build but a development one.
class DevKeyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = File.realpath(Dir.mktmpdir('erx-dev-key-'))
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @keys = File.join(@directory, 'clone', Erx::DevKey::DIRECTORY)
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def test_a_pair_is_made_once_and_kept
    made = Erx::DevKey.ensure(directory: @keys, runner: @runner)
    assert_match(/\Assh-ed25519 [A-Za-z0-9+\/]+=*\z/, made.public_line)
    assert_equal 0o600, File.stat(made.private_path).mode & 0o777
    assert_equal 0o700, File.stat(@keys).mode & 0o777
    private_bytes = File.binread(made.private_path)
    assert_equal made, Erx::DevKey.ensure(directory: @keys, runner: @runner)
    assert_equal private_bytes, File.binread(made.private_path)
    assert_equal [Erx::DevKey::PRIVATE, Erx::DevKey::PUBLIC].sort, Dir.children(@keys).sort
    assert_equal [File.basename(@keys)], Dir.children(File.dirname(@keys)), 'no fresh directory is left beside the pair'
    refute_includes made.public_line, Erx::DevKey::COMMENT
  end

  def test_halves_that_disagree_or_a_damaged_pair_are_refused
    made = Erx::DevKey.ensure(directory: @keys, runner: @runner)
    other = Erx::DevKey.ensure(directory: File.join(@directory, 'other'), runner: @runner)
    public_path = File.join(@keys, Erx::DevKey::PUBLIC)
    File.write(public_path, "#{other.public_line} someone@somewhere\n")
    error = assert_raises(Erx::Error) { Erx::DevKey.ensure(directory: @keys, runner: @runner) }
    assert_includes error.message, 'disagree'
    File.write(public_path, "ssh-rsa AAAA\n")
    assert_raises(Erx::Error) { Erx::DevKey.ensure(directory: @keys, runner: @runner) }
    File.write(public_path, "#{made.public_line}\n")
    File.write(made.private_path, 'not a key')
    error = assert_raises(Erx::Error) { Erx::DevKey.ensure(directory: @keys, runner: @runner) }
    assert_includes error.message, 'cannot read'
    File.chmod(0o644, made.private_path)
    error = assert_raises(Erx::Error) { Erx::DevKey.ensure(directory: @keys, runner: @runner) }
    assert_includes error.message, 'owner-only'
  end

  # A pair that another build renamed into place first wins: the loser's fresh
  # directory is removed and the winner's pair is the one read.
  def test_a_pair_made_by_a_racing_build_is_kept
    winner = Erx::DevKey.ensure(directory: File.join(@directory, 'winner'), runner: @runner)
    racing = Class.new(SimpleDelegator) do
      define_method(:initialize) do |runner, place, from|
        super(runner)
        @place = place
        @from = from
      end
      define_method(:run) do |argv, **options|
        result = __getobj__.run(argv, **options)
        FileUtils.cp_r(@from, @place, preserve: true) if argv.include?('-q') && !File.exist?(@place)
        result
      end
    end
    pair = Erx::DevKey.ensure(directory: @keys, runner: racing.new(@runner, @keys, winner.directory))
    assert_equal winner.public_line, pair.public_line
    assert_equal [File.basename(@keys)], Dir.children(File.dirname(@keys))
  end

  def test_the_ssh_argument_vector_keeps_the_key_out_of_the_agent
    pair = Erx::DevKey::Pair.new(directory: '/k', public_line: 'unused')
    assert_equal ['ssh', '-F', '/dev/null', '-o', 'AddKeysToAgent=no', '-o', 'IdentitiesOnly=yes',
                  '-a', '-x', '-o', 'ClearAllForwardings=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                  '-o', 'StrictHostKeyChecking=accept-new', '-o', 'GlobalKnownHostsFile=/dev/null',
                  '-o', 'UserKnownHostsFile=/boot/known_hosts', '-o', 'HostKeyAlias=erxos-development',
                  '-i', '/k/id_ed25519', '-p', '2222', '--', 'root@127.0.0.1'],
                 Erx::DevKey.ssh_argv(pair: pair, port: 2222, known_hosts: '/boot/known_hosts')
    # A command is one argument after the destination, which ssh sends unchanged.
    assert_equal ['--', 'root@127.0.0.1', 'echo hi'],
                 Erx::DevKey.ssh_argv(pair: pair, port: 2222, known_hosts: '/boot/known_hosts', command: 'echo hi').last(3)
    # An empty command would ask for a shell, and an array would be several arguments.
    ['', %w[echo hi]].each do |command|
      assert_raises(Erx::Error) { Erx::DevKey.ssh_argv(pair: pair, port: 2222, known_hosts: '/boot/known_hosts', command: command) }
    end
    ['-oProxyCommand=x', 'root@elsewhere', ''].each do |user|
      assert_raises(Erx::Error) { Erx::DevKey.ssh_argv(pair: pair, port: 2222, known_hosts: '/boot/known_hosts', user: user) }
    end
  end

  # ssh splits a known-hosts path at whitespace and expands ~, % and ${} in it and in
  # an identity file's path: such a known-hosts path is refused, and so is such a key
  # directory, once, when its pair is made.
  PATHS_SSH_WOULD_REWRITE = ['/a b/known_hosts', '/a/%d', '/a/${HOME}', '~/known_hosts', 'relative', "/a/\"b"].freeze

  def test_a_path_ssh_would_rewrite_is_refused
    pair = Erx::DevKey::Pair.new(directory: '/k', public_line: 'unused')
    PATHS_SSH_WOULD_REWRITE.each do |path|
      assert_raises(Erx::Error) { Erx::DevKey.ssh_argv(pair: pair, port: 2222, known_hosts: path) }
      assert_raises(Erx::Error) { Erx::DevKey::Pair.new(directory: path, public_line: 'unused') }
    end
  end

  # The packer's one funnel refuses the login key's file under any release in a
  # release build; a development build goes on past it to its next check.
  def test_a_release_build_carries_no_login_key
    codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    tools = Erx::PackTools.build(root: ROOT, owner_root: @directory, directory: File.join(@directory, 'tools'), runner: @runner)
    artifact = File.join(@directory, 'authorized_keys')
    File.write(artifact, "ssh-ed25519 AAAA\n")
    pack = Erx::Pack.new(root: ROOT, output_root: @directory, codec: codec, planner: nil,
                         checker: tools.fetch('checker'), hasher: tools.fetch('hasher'), runner: @runner,
                         provenance: KnownProvenance.new)
    entry = { 'path' => "domains/erxos/#{codec.fixed_bytes('ssh_authorized_keys_path')}", 'kind' => codec.member('entry_kind', 'file'),
              'flags' => 0, 'artifact' => artifact, 'receipt' => 'unused', 'id' => 'login-key' }
    build = lambda do |kind|
      assert_raises(Erx::Error) do
        pack.build(entries: [entry], root_path: 'system/root', build_kind: kind, platform: nil, artifacts: {},
                   manifest_source: '', output: File.join(@directory, 'out', 'image.erxpack'))
      end
    end
    assert_equal 'a release build carries no development login key', build.call('release').message
    assert_equal 'root image is absent from the pack', build.call('development').message
  end

  # The file the image build writes into each release holds the public line it was
  # handed, newline-terminated, and its receipt names the code that writes it.
  def test_the_image_build_writes_the_public_line
    require_relative '../../tools/lib/erx/production_image'
    line = Erx::DevKey.ensure(directory: @keys, runner: @runner).public_line
    image = Erx::ProductionImage.allocate
    image.instance_variable_set(:@root, ROOT)
    image.instance_variable_set(:@login_key, line)
    file = image.send(:login_key_file, directory: @directory)
    assert_equal "#{line}\n", File.binread(file.fetch('artifact'))
    receipt = JSON.parse(File.read(file.fetch('receipt')))
    assert_equal Erx::ProductionImage::LOGIN_KEY_SOURCES, receipt.fetch('sources').map { |source| source.fetch('path') }
  end

  class KnownProvenance
    def resolve(**_arguments) = [].freeze
    def artifact_hash(path) = Digest::SHA256.file(path).hexdigest
  end
end
