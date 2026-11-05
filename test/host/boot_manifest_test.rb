# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/manifest_context'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/manifest'

# erx-gate: sanitizers

# What the boot information page takes from the system manifest, the same on both entries
# (docs/design-stopgap.md, "Boot information"): liberx/backend/core/boot_manifest.c over a
# manifest Manifest.admit wrote from config/manifest/qemu-virt-development.txt, driven by
# test/fixtures/boot_manifest_driver.c.
class BootManifestTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[liberx/backend/core/boot_manifest.c liberx/generated/abi_reader.c test/fixtures/boot_manifest_driver.c].freeze

  def setup
    @directory = Dir.mktmpdir('erx-boot-manifest-')
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    @source = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))
    @driver = build
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
    output = File.join(@directory, 'driver')
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', *flags,
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, *SOURCES.map { |source| File.join(ROOT, source) },
                                  '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def admitted(source = @source)
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform, build_kind: 'development'))
    Erx::Manifest.admit(source: source, codec: @codec, context: context).bytes
  end

  def read(bytes)
    path = File.join(@directory, 'manifest.bin')
    File.binwrite(path, bytes)
    Open3.capture2e(@driver, path, stdin_data: '')
  end

  def test_the_page_takes_the_node_the_words_and_the_limits_of_the_source
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "node system@erxos\n"
    assert_includes output, "words-- -root / -bindir /bin -progname erl -home / -boot /bin/start -user erx_console -nocookie -kernel start_distribution false \n"
    assert_includes output, "limits 65536 1048576 64 256 0 0 65536 1024 4096\n"
  end

  def test_a_manifest_with_no_system_args_gives_no_words
    output, status = read(admitted(@source.sub(/^  system_args .*\n/, '')))
    assert status.success?, output
    assert_includes output, "words\nlimits"
  end

  def test_a_word_list_in_hexadecimal_passes_as_written
    output, status = read(admitted(@source.sub(/^  system_args .*\n/, "  system_args hex:2d61006200\n")))
    assert status.success?, output
    assert_includes output, "words-a b \n"
  end

  # ERTS echoes a flag it does not know to the terminal, so these bytes would be a terminal escape.
  def test_a_word_outside_printable_ascii_is_refused
    %w[2d5a1b5d323b7265766965770700 2d5a7f00 2d5ac29b00 2d5ae280ae00].each do |word|
      output, status = read(admitted(@source.sub(/^  system_args .*\n/, "  system_args hex:#{word}\n")))
      assert_equal 1, status.exitstatus, output
      assert_equal "refused system_args_text\n", output
    end
  end

  def test_a_truncated_or_empty_manifest_is_refused_with_its_check
    bytes = admitted
    [bytes.byteslice(0, bytes.bytesize - 1), bytes.byteslice(0, 16), ''.b].each do |cut|
      output, status = read(cut)
      assert_equal 1, status.exitstatus, output
      assert_match(/\Arefused \S+/, output)
    end
  end

  def test_a_word_list_without_its_last_nul_is_refused_by_the_reader
    bytes = admitted.dup
    args = bytes.index("false\0".b)
    bytes.setbyte(args + 5, 'x'.ord)
    output, status = read(bytes)
    assert_equal 1, status.exitstatus, output
    assert_match(/\Arefused /, output)
  end
end
