# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'libcxx'
require_relative 'native_runtime'

module Erx
  # ERTS's BeamAsm flavour for the BeamAsm image (docs/design-runtime.md, "The build"):
  # OTP's configure run a second time, with the JIT enabled, in a private copy of its
  # own, and the emulator alone made with FLAVOR=jit. The interpreter build comes first
  # and lends its musl sysroot and liberx archive; the release's beams are the same
  # bytes for both images, so they come from the interpreter build alone. BeamAsm's C++
  # compiles with libc++'s headers first and without exceptions or RTTI, and OTP's own
  # link takes libc++ and libc++abi (Libcxx).
  class NativeJitRuntime < NativeRuntime
    BASE = 'build/runtime/native-jit'
    FLAVOR = 'jit'
    # What the BeamAsm image's link takes: this flavour's own OTP archives, the
    # interpreter build's musl libc.a and compiler-rt builtins, and the C++ runtime's archives.
    Built = Data.define(:otp_archives, :libc, :builtins, :otp, :cxx_archives) do
      # The link's archives in link order, with the builtins last.
      def link_archives = [*otp_archives, libc, *cxx_archives, builtins]
    end

    def self.output(root:) = flavour_output(root: root, base: BASE, flavour: FLAVOR)

    # interpreter is the interpreter build's Built, which must already be built: its
    # sysroot is what libc++ and this flavour compile against. Make and ninja decide
    # what is stale, so a build after no change costs seconds. @libcxx is set first,
    # since the configure stamp, the environment and the import check all read it.
    def build(interpreter:, jobs: 4)
      @oracle.verify(HOST_OTP_FLAVOUR)
      FileUtils.rm_f(self.class.record_path(@output))
      digest = self.class.source_digest(root: @root, generated: @generated)
      @libcxx = Libcxx.new(root: @root, runner: @runner, compiler: @compiler, target_flags: target_flags).build(jobs: jobs)
      copy_sources
      configure unless File.file?(in_copy('.erx-configured'))
      build_emulator(jobs: jobs)
      check_imports
      File.write(self.class.record_path(@output), digest)
      Built.new(otp_archives: [File.join(@output.objects, 'erl_main.o'), File.join(File.dirname(@output.beam), 'libbeam.a'),
                               *RuntimeSeam.libraries(@output, target: TARGET)].freeze,
                libc: interpreter.libc, builtins: interpreter.builtins, otp: @output.root, cxx_archives: @libcxx.archives)
    end

    private

    def check_imports = check_imports_of(cxx_runtime: @libcxx.archives)

    # The configure stamp records libc++'s configuration beside the sysroot: a change to
    # it changes the headers every C++ object was compiled with, which OTP's make does
    # not track, so the copy starts again.
    def sdk_root = [@sysroot, @libcxx.configuration].join("\n")

    def flavour_environment
      { 'ERX_JIT' => '--enable-jit', 'ERX_CXX_INCLUDE' => @libcxx.include,
        'ERX_CXX_LIBS' => "-L#{File.dirname(@libcxx.archives.first)} -lc++ -lc++abi" }
    end
  end
end
