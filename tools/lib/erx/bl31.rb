# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'build_memo'
require_relative 'json_input'
require_relative 'dependencies'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # TF-A 2.15.0's BL31 for the Raspberry Pi 4, the boot stub that gives the board PSCI
  # (docs/design-platforms.md, "Firmware"): built for the development host's LLVM from
  # deps.lock's pin `trusted-firmware-a` into build/bl31, out of the source tree, with
  # its console off once the kernel runs. TF-A's make runs with GNU sed first on the
  # path, which its makefiles need and macOS's sed is not.
  #
  # patch_stub writes the stub header the Pi firmware fills before it starts BL31, for
  # the QEMU model, where no firmware runs (docs/research-rpi4-bl31-qemu.md).
  module Bl31
    SOURCE_ID = 'trusted-firmware-a'
    OUTPUT = 'build/bl31'
    IMAGE = 'bl31.bin'
    STAMP = 'build.json'
    DEADLINE = 900
    # TF-A's build options. ERRATA_A72_1319367 is the Cortex-A72 erratum the debug build
    # warns about; RPI3_RUNTIME_UART -1 turns BL31's console off once the kernel runs;
    # a fixed build string and message keep the image the same from build to build (the
    # default asks git, which would find erXos's own tree around the source).
    OPTIONS = %w[PLAT=rpi4 DEBUG=0 ERRATA_A72_1319367=1 RPI3_RUNTIME_UART=-1
                 BUILD_STRING=v2.15.0 BUILD_MESSAGE_TIMESTAMP="erXos"].freeze
    # Where Homebrew's GNU sed answers to the name sed.
    GNU_SED = '/opt/homebrew/opt/gnu-sed/libexec/gnubin'
    # BL31 runs from address 0 in the memory the firmware keeps for the stub, the first
    # 512 KiB, which the device tree's reserved memory states.
    MAX_IMAGE = 512 * 1024
    # TF-A's licence in its source, which ships beside the binary.
    LICENCE = 'docs/license.rst'

    # The stub header at 0xf0 (TF-A's plat/rpi/common/aarch64/armstub8_header.S): the
    # magic, a version, the device tree's address and the kernel's entry, each a 32-bit
    # little-endian word. The firmware clears the magic once it has written the two
    # addresses; BL31 reads them only then, and otherwise enters 0x80000 with no tree.
    STUB_OFFSET = 0xf0
    STUB_MAGIC = 0x5afe570b
    STUB_LAYOUT = 'L<4'
    STUB_BYTES = 16
    DTB_WINDOW = 1 << 20

    module_function

    # bytes, a built bl31.bin, with its stub header filled as the firmware fills it: the
    # magic cleared, the device tree at dtb and the kernel's entry at entry. Pure: it
    # returns a new string and refuses an image that is not an unfilled stub, or an
    # address the header cannot hold or BL31 cannot use.
    def patch_stub(bytes, dtb:, entry:)
      raise Error, 'BL31 image is shorter than its stub header' if bytes.bytesize < STUB_OFFSET + STUB_BYTES

      magic = bytes.byteslice(STUB_OFFSET, 4).unpack1('L<')
      raise Error, format('BL31 stub header magic is 0x%08x, not 0x%08x', magic, STUB_MAGIC) unless magic == STUB_MAGIC

      { 'device tree' => [dtb, 8], 'kernel entry' => [entry, 4] }.each do |name, (address, alignment)|
        unless address.is_a?(Integer) && address.positive? && address < (1 << 32) && (address % alignment).zero?
          raise Error, "BL31 stub header: the #{name} address must be a nonzero 32-bit address aligned to #{alignment}"
        end
      end
      raise Error, 'BL31 stub header: the kernel entry lies inside BL31' if entry < MAX_IMAGE
      # BL31 opens the tree in place with 1 MiB to grow into (TF-A's rpi4_prepare_dtb).
      raise Error, 'BL31 stub header: the device tree lies inside BL31' if dtb < MAX_IMAGE
      raise Error, 'BL31 stub header: the device tree and the kernel entry overlap' if (dtb...dtb + DTB_WINDOW).cover?(entry)

      patched = bytes.b
      patched[STUB_OFFSET, STUB_BYTES] = [0, 0, dtb, entry].pack(STUB_LAYOUT)
      patched
    end

    # The built image, or nil when it is missing or was built from another pin, recipe or
    # toolchain, so a caller rebuilds it.
    def locate(root:, compiler:, linker:)
      image = File.join(root, OUTPUT, IMAGE)
      stamp = File.join(root, OUTPUT, STAMP)
      return nil unless File.file?(image) && File.file?(stamp)

      recorded = begin
        JsonInput.parse(BoundedFile.read(stamp, maximum: 65_536), max_bytes: 65_536, label: 'BL31 build record')
      rescue JsonInput::Unsupported
        raise
      rescue Error
        nil
      end
      recorded == record(root: root, compiler: compiler, linker: linker) ? image : nil
    end

    def ensure(root:, runner:, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
      locate(root: root, compiler: compiler, linker: linker) ||
        build(root: root, runner: runner, compiler: compiler, linker: linker)
    end

    def licence(root:, runner:) = File.join(Dependencies.new(root: root, runner: runner).fetched_tree(SOURCE_ID), LICENCE)

    # What a build is of: TF-A's pin, this recipe and its options, and the compiler and
    # linker by identity (BuildMemo.program_identity), so a changed toolchain rebuilds.
    def record(root:, compiler:, linker:)
      raise Error, 'BL31 needs ERX_CLANG and ERX_LLD, LLVM\'s clang and ld.lld' if compiler.to_s.empty? || linker.to_s.empty?

      { 'source' => source_record(root: root), 'recipe' => Digest::SHA256.file(__FILE__).hexdigest,
        'options' => OPTIONS, 'compiler' => BuildMemo.program_identity(compiler),
        'linker' => BuildMemo.program_identity(linker) }
    end

    # Removes the last build, so the next ensure builds again: the reproducibility check
    # builds BL31 once for each of its images.
    def clean(root:)
      destination = OutputDirectory.check(root: root, path: File.join(root, OUTPUT))
      FileUtils.rm_rf(destination)
    end

    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    # TF-A's make writes only under BUILD_BASE, a fresh directory under build/, so the
    # fetched source stays as fetch verified it.
    def build(root:, runner:, compiler:, linker:)
      raise Error, 'BL31 needs ERX_CLANG and ERX_LLD, LLVM\'s clang and ld.lld' if compiler.empty? || linker.empty?
      raise Error, "BL31's build needs GNU sed (brew install gnu-sed): no #{GNU_SED}/sed" unless
        File.executable?(File.join(GNU_SED, 'sed'))

      tree = Dependencies.new(root: root, runner: runner).fetched_tree(SOURCE_ID)
      build = OutputDirectory.prepare(root: root, path: File.join(root, 'build'))
      Dir.mktmpdir('.bl31-', build) do |work|
        runner.run(['gmake', '-C', tree, "BUILD_BASE=#{work}", "CC=#{compiler}", "LD=#{linker}", *OPTIONS, 'bl31'],
                   name: 'bl31-build', deadline: DEADLINE,
                   env: { 'PATH' => [GNU_SED, ENV.fetch('PATH', '')].join(File::PATH_SEPARATOR) })
        output = File.join(work, 'out')
        Dir.mkdir(output)
        File.binwrite(File.join(output, IMAGE), BoundedFile.read(File.join(work, 'rpi4/release', IMAGE), maximum: MAX_IMAGE))
        File.write(File.join(output, STAMP), JSON.pretty_generate(record(root: root, compiler: compiler, linker: linker)) + "\n")
        publish(output, destination: File.join(root, OUTPUT))
      end
      locate(root: root, compiler: compiler, linker: linker) || raise(Error, "BL31 build left no #{IMAGE} in #{OUTPUT}")
    end

    # The new output replaces the old whole.
    def publish(output, destination:)
      raise Error, "BL31 output is a symbolic link: #{destination}" if File.symlink?(destination)

      FileUtils.rm_rf(destination)
      File.rename(output, destination)
    end
  end
end
