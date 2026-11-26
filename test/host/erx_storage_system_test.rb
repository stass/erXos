# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/app_package'
require_relative '../../tools/lib/erx/erofs_image'
require_relative '../../tools/lib/erx/image_apps'
require_relative '../../tools/lib/erx/release_medium'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_storage_system_tests.erl, the EUnit cases of the `system` tree's
# backend, erx_storage_system (docs/design-storage.md, "The `system` tree" and E1),
# served through erx_fs grants over a RAM window on a system partition: an EROFS image
# fsimg writes with the packer's options (Erx::ErofsImage), its `apps/` holding two
# packages and its root one file more, followed by its dm-verity tree
# (Erx::AppPackage.verity_tree), and the `-erx_record system_image` words that name it,
# which the cases read through erx_device_record:system_image/1.
#
# Partitions, written as NAME.img with their record's words in system.terms:
# "good"; "directory", good's bytes with one bit of the `apps/` directory's entry names
# flipped and good's record; "changed", an image whose package has other bytes of the
# same length, its tree rebuilt to match, with good's record; and "changed-own", the
# changed partition with the record of its own tree; and "packed", the partition the
# packer writes (Erx::ReleaseMedium.image) from a release file and the image's packages,
# big and small, with the record of the artifacts it hands the manifest check; and
# "packed-empty", the partition it writes from the release file and no package.
class ErxStorageSystemTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_storage].freeze
  # Compiled again with TEST, which exports mount/3 to the cases.
  SYSTEM = 'erlang/apps/erx_storage/src/erx_storage_system.erl'
  TESTS = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_erofs_tests.erl
             test/erlang/stand_in/erx_dist.erl test/erlang/erx_storage_system_tests.erl].freeze
  INCLUDES = [File.join(ROOT, 'otp/lib/kernel/include')].freeze
  SALT = "\x5a".b * 8
  # The arities of mount the compiled module exports.
  EXPORTS = 'io:format("~w~n", [[A || {mount, A} <- erx_storage_system:module_info(exports)]]), halt().'
  # The packages' sizes and the seeds of their bytes, as erx_erofs_tests:contents/2 makes
  # them: big.app spans several blocks and ends inside one.
  PACKAGES = { 'big.app' => [20_000, 3], 'small.app' => [100, 1] }.freeze
  # Empty files that make apps/ span directory blocks of its own, past block 0, which the
  # superblock's CRC-32C covers, so that only the hash check can catch a change there.
  PADS = (0...80).map { |index| format('pad-%04d-with-a-name-long-enough-to-fill-blocks.app', index) }.freeze

# The module as the build compiles it, without TEST, exports no mount: the mint mounts
  # the tree with mount/1, which reads the boot record itself (E1), and mount/3, which
  # takes the record's answer from its caller, reaches only the cases.
  def test_the_shipped_module_exports_no_mount
    Dir.mktmpdir('erx-storage-system-shipped') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', EXPORTS, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_equal '[]', output.strip
    end
  end

  def test_system_tree_cases_pass_under_eunit
    Dir.mktmpdir('erx-storage-system-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, includes: INCLUDES,
                          replaced: { SYSTEM => File.read(File.join(ROOT, SYSTEM)) }, defines: %w[TEST])
      write_partitions(work)
      output, status = Open3.capture2e({ 'ERX_SYSTEM_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                                       '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_storage_system_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
      # The seed of the exports probe: the same module compiled with TEST shows mount/3.
      output, = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                '-eval', EXPORTS, chdir: work, stdin_data: '')
      assert_equal '[3]', output.strip
    end
  end

  private

  def write_partitions(work)
    runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
    good = image(work, runner, 'good', seed_shift: 0)
    changed = image(work, runner, 'changed', seed_shift: 1)
    good_tree = Erx::AppPackage.verity_tree(good, salt: SALT)
    changed_tree = Erx::AppPackage.verity_tree(changed, salt: SALT)
    raise 'the changed image must keep the good image length' unless changed.bytesize == good.bytesize

    partitions = { 'good' => [good + good_tree.bytes, record(good, good_tree)],
                   'directory' => [flip_name(good) + good_tree.bytes, record(good, good_tree)],
                   'changed' => [changed + changed_tree.bytes, record(good, good_tree)],
                   'changed-own' => [changed + changed_tree.bytes, record(changed, changed_tree)] }
    partitions['packed'] = packed(work, runner, 'packed', PACKAGES)
    partitions['packed-empty'] = packed(work, runner, 'packed-empty', {})
    terms = partitions.map do |name, (bytes, words)|
      File.binwrite(File.join(work, "#{name}.img"), bytes)
      "{\"#{name}\", [#{words.map { |word| "\"#{word}\"" }.join(', ')}]}.\n"
    end
    names = (PACKAGES.keys + PADS).sort.map { |name| "<<\"#{name}\">>" }
    File.write(File.join(work, 'system.terms'), terms.join + "{names, [#{names.join(', ')}]}.\n")
  end

  # The EROFS image of a partition: apps/ with PACKAGES, their seeds moved by seed_shift,
  # with PADS, and README at the root, outside the tree's root.
  def image(work, runner, name, seed_shift:)
    sources = File.join(work, "#{name}-files")
    Dir.mkdir(sources)
    files = PACKAGES.to_h do |package, (size, seed)|
      path = File.join(sources, package)
      File.binwrite(path, contents(size, seed + seed_shift))
      ["apps/#{package}", path]
    end
    pad = File.join(sources, 'pad')
    File.binwrite(pad, '')
    files.merge!(PADS.to_h { |name| ["apps/#{name}", pad] })
    readme = File.join(sources, 'README')
    File.binwrite(readme, "outside apps\n")
    output = Erx::ErofsImage.new(runner: runner, root: ROOT).write(files: files.merge('README' => readme), name: name,
                                                                    output: File.join(work, "#{name}.erofs"))
    File.binread(output)
  end

  # The partition the packer writes for a release of one file, system/README, and the
  # image's packages listed, staged in work/LABEL-files, and the record words of its artifact: the image, then its
  # tree from the image's end.
  def packed(work, runner, label, listed)
    sources = File.join(work, "#{label}-files")
    Dir.mkdir(sources)
    packages = listed.map do |file, (size, seed)|
      path = File.join(sources, file)
      File.binwrite(path, contents(size, seed))
      Erx::ImageApps::Package.new(path: path, name: File.basename(file, '.app'), memory: 1 << 22, sha256: "\0".b * 32,
                                  license: 'BSD-2-Clause')
    end
    readme = File.join(sources, 'README')
    File.binwrite(readme, "outside apps\n")
    erofs, artifacts = Erx::ReleaseMedium.image(entries: [{ 'path' => 'system/README', 'artifact' => readme }],
                                                apps: Erx::ImageApps.plan(packages, enable: []), directory: sources, runner: runner)
    image = File.binread(erofs)
    tree = artifacts.fetch(Erx::ReleaseMedium::IMAGE).fetch('tree')
    [image + Erx::AppPackage.image_tree(image).bytes,
     ['system_image', image.bytesize, *tree.values_at('offset', 'length', 'salt', 'root_hash')]]
  end

  # The words of `-erx_record system_image` after the role, as the domain library writes them.
  def record(image, tree) = ['system_image', image.bytesize, image.bytesize, tree.bytes.bytesize,
                             SALT.unpack1('H*'), tree.root_hash.unpack1('H*')]

  # image with the low bit of the last byte of the name big.app flipped, a byte of the
  # apps/ directory's first block, so that it reads big.apq, still in the entries' order:
  # unchecked, the reader would parse the block and answer enoent for big.app.
  def flip_name(image)
    at = image.index('big.app') or raise 'the image holds no entry big.app'
    raise 'the entry big.app lies in block 0' if at < 4096

    image.dup.tap { |bytes| bytes.setbyte(at + 6, bytes.getbyte(at + 6) ^ 1) }
  end

  def contents(size, seed) = (0...size).map { |index| (index * 7 + seed) & 255 }.pack('C*')
end
