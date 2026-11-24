# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'json'
require 'open3'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/fsimg'
require_relative '../../tools/lib/erx/netboot'
require_relative '../../tools/lib/erx/runner'

# Netboot's HTTP form (Erx::Netboot.prepare, point and stage_http; Erx::NetbootEntry): a
# queue holds each distinct set once and an entry per boot, each boot.img a FAT32 of its
# set's files whose cmdline.txt ends in the entry's boot name, signed with a key made
# here for the test, and the way back is the found target's last pair byte for byte.
class NetbootHttpTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FSIMG = Erx::Fsimg.locate(root: ROOT)
  NAMES = %w[0123456789abcdef0123456789abcdef fedcba9876543210fedcba9876543210 00112233445566778899aabbccddeeff].freeze

  def setup
    @scratch = Dir.mktmpdir('erx-netboot-http-test-')
    @root = File.join(@scratch, 'http')
    @key = File.join(@scratch, 'keys', 'private.pem')
    Dir.mkdir(File.dirname(@key), 0o700)
    @rsa = OpenSSL::PKey::RSA.new(2048)
    File.write(@key, @rsa.to_pem, perm: 0o600)
    @runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def test_a_queue_holds_each_set_once_and_signed_entries_and_the_found_pair_last
    stage = Erx::Netboot.stage_http(medium: medium('a', cmdline: 'erx.hostlink=1'), root: @root, key: @key, **tools)
    found = Erx::Netboot.found(@root)
    assert_equal File.realpath(stage.directory), found.target
    before = digests(found.target)
    sets = [set('a', cmdline: 'erx.hostlink=1'), set('b'), set('a', cmdline: 'erx.hostlink=1')]
    queue = Erx::Netboot.prepare(root: @root, sets: sets, names: NAMES, key: @key, found: found, **tools)

    assert_equal %w[1 2], Dir.children(File.join(queue, 'sets')).sort, 'each distinct set is copied once'
    assert_equal %w[1 2 3 4 sets], Dir.children(queue).sort
    { 1 => ['a', "erx.hostlink=1 erx.arg=#{NAMES[0]}"], 2 => ['b', "erx.arg=#{NAMES[1]}"],
      3 => ['a', "erx.hostlink=1 erx.arg=#{NAMES[2]}"] }.each do |number, (tag, cmdline)|
      entry = File.join(queue, number.to_s)
      assert_equal files(tag).merge('cmdline.txt' => cmdline), image_files(File.join(entry, 'boot.img'), files(tag).keys + ['cmdline.txt'])
      assert_signed entry
    end
    assert_equal pair(File.join(found.target, '1')), pair(File.join(queue, '4')), 'the way back is the found pair'

    Erx::Netboot.point(root: @root, target: queue)
    assert_equal File.realpath(queue), File.realpath(@root)
    Erx::Netboot.point(root: @root, target: found.target)
    assert_equal [found.target, before], [File.realpath(@root), digests(found.target)]
  end

  def test_no_found_pair_makes_an_empty_way_back
    queue = Erx::Netboot.prepare(root: @root, sets: [set('a')], names: NAMES.take(1), key: @key,
                                 found: Erx::Netboot.found(@root), **tools)
    assert_empty Dir.children(File.join(queue, '2'))
    refute File.exist?(@root), 'prepare does not touch the link'
  end

  def test_a_stage_serves_one_entry_and_removes_the_stale_queue
    first = Erx::Netboot.stage_http(medium: medium('a'), root: @root, key: @key, **tools)
    second = Erx::Netboot.stage_http(medium: medium('b'), root: @root, key: @key, **tools)
    refute File.exist?(first.directory)
    assert_equal %w[1 sets], Dir.children(second.directory).sort
    assert_match(/\Aerx\.arg=\h{32}\z/, image_files(File.join(@root, '1', 'boot.img'), ['cmdline.txt']).fetch('cmdline.txt'))
    assert_equal Digest::SHA256.hexdigest(files('b').fetch('kernel8.img')), second.kernel
  end

  # A set's command line with a line break would put the boot name on a line of its own.
  def test_a_set_command_line_with_a_line_break_is_refused
    error = assert_raises(Erx::Error) do
      Erx::Netboot.prepare(root: @root, sets: [set('n', cmdline: "erx.hostlink=1\n")], names: NAMES.take(1), key: @key, **tools)
    end
    assert_match(/cmdline.txt holds a line break/, error.message)
  end

  def test_the_key_is_taken_only_as_the_users_own_private_file
    File.chmod(0o640, @key)
    assert_refused(/grants permission to group or others/)
    File.chmod(0o600, @key)
    File.symlink(@key, File.join(@scratch, 'link.pem'))
    assert_refused(/is a symbolic link/, key: File.join(@scratch, 'link.pem'))
    assert_refused(/is not a regular file/, key: File.dirname(@key))
    File.write(@key, 'no key', perm: 0o600)
    assert_refused(/holds no RSA private key/)
    File.write(@key, OpenSSL::PKey::RSA.new(1024).to_pem, perm: 0o600)
    assert_refused(/is no RSA-2048 private key/)
  end

  private

  def tools = { runner: @runner, fsimg: FSIMG }

  # The boot files of build tag: kernel8.img of several clusters, the firmware's, a
  # long name and an overlay, each its build's own.
  def files(tag)
    %w[start4.elf fixup4.dat config.txt bl31.bin bcm2711-rpi-4-b.dtb overlays/uart3.dtbo]
      .to_h { |name| [name, "#{name} of build #{tag}\n"] }
      .merge('kernel8.img' => Random.new(tag.ord).bytes(5000) + tag)
  end

  # A production image's directory for build tag, with cmdline.txt when cmdline is given.
  def medium(tag, cmdline: nil)
    directory = File.join(@scratch, "medium-#{tag}")
    return directory if File.directory?(directory)

    listed = files(tag).merge(cmdline ? { 'cmdline.txt' => cmdline } : {})
    listed.each do |name, bytes|
      path = File.join(directory, 'boot', name)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
    end
    image = File.join(directory, 'sdcard.img')
    File.write(image, "card #{tag}")
    receipt = Erx::BootPartition.receipt({ 'source' => { 'commit' => 'c' * 40, 'dirty' => false } }, image: image,
                                         files: listed.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
                                         pieces: {})
    File.write(File.join(directory, 'sdcard.img.receipt.json'), JSON.generate(receipt))
    directory
  end

  def set(tag, cmdline: nil) = Erx::Netboot.boot_set(medium(tag, cmdline: cmdline))

  # Each of names as fsimg extracts it from image.
  def image_files(image, names)
    names.to_h do |name|
      output, status = Open3.capture2(FSIMG, 'x', '-O', '-f', image, name, stdin_data: '', binmode: true, err: File::NULL)
      assert status.success?, "fsimg could not extract #{name}"
      [name, output]
    end
  end

  def assert_signed(entry)
    image = File.binread(File.join(entry, 'boot.img'))
    digest, stamp, signature = File.read(File.join(entry, 'boot.sig')).lines.map(&:chomp)
    assert_equal Digest::SHA256.hexdigest(image), digest
    assert_match(/\Ats: \d+\z/, stamp)
    assert @rsa.public_key.verify('SHA256', [signature.delete_prefix('rsa2048: ')].pack('H*'), image), 'boot.sig verifies'
  end

  def pair(entry) = %w[boot.sig boot.img].map { |name| File.binread(File.join(entry, name)) }

  def digests(directory)
    Dir.glob('**/*', base: directory).reject { |name| File.directory?(File.join(directory, name)) }
       .to_h { |name| [name, Digest::SHA256.file(File.join(directory, name)).hexdigest] }
  end

  def assert_refused(pattern, key: @key)
    error = assert_raises(Erx::Error) { Erx::Netboot.prepare(root: @root, sets: [set('a')], names: NAMES.take(1), key: key, **tools) }
    assert_match pattern, error.message
    refute_includes error.message, 'PRIVATE KEY'
    assert_empty Dir.children(@scratch).grep(/\Ahttp\./), 'no queue is left'
  end
end
