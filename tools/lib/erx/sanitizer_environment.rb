# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'
require_relative 'error'
require_relative 'host_os'

module Erx
  # The environment every sanitized program in host tooling runs under: the
  # ASAN_OPTIONS, UBSAN_OPTIONS and TSAN_OPTIONS strings, built from one
  # policy. tools/erx's host_environment takes the policy as it stands; a test
  # passes only the options it changes, which replace the policy's option of
  # the same name. The result always sets all three variables, so a caller
  # never inherits a variable it did not mean to keep, and no caller can drop
  # the policy or the symbolizer by restating one variable.
  #
  # Every string names the build's own llvm-symbolizer because the runtimes'
  # default on macOS is `atos -p PID`, which attaches to the failing process
  # and can hang there indefinitely, so a test that expects a sanitizer report
  # waits until its deadline kills it. llvm-symbolizer reads the binary
  # instead. It comes from the directory of the compiler that built the
  # program, the one LLVM the build uses; when it is not there the call fails
  # with a diagnostic rather than letting the runtime fall back to atos.
  module SanitizerEnvironment
    module_function

    # Halt on the first report, take every check the host supports, and let
    # allocations fail so failure handling runs. LeakSanitizer, and with it
    # the initialization-order checks, run only on Linux: macOS and FreeBSD
    # have no LeakSanitizer, and their AddressSanitizer refuses to start
    # when asked for it.
    LEAK_SANITIZER = HostOs::LINUX
    POLICY = {
      asan: %w[halt_on_error=1 abort_on_error=1 detect_stack_use_after_return=1 allocator_may_return_null=1] +
        (LEAK_SANITIZER ? %w[detect_leaks=1 check_initialization_order=1 strict_init_order=1] : %w[detect_leaks=0]),
      ubsan: %w[halt_on_error=1 print_stacktrace=1 report_error_type=1],
      tsan: %w[halt_on_error=1 abort_on_error=1 exitcode=66]
    }.transform_values(&:freeze).freeze
    VARIABLES = { asan: 'ASAN_OPTIONS', ubsan: 'UBSAN_OPTIONS', tsan: 'TSAN_OPTIONS' }.freeze
    SYMBOLIZER = 'llvm-symbolizer'
    OPTION = /\A[a-z0-9_]+=[^\s:,'"\\]+\z/
    # The sanitizer option parser splits on whitespace, colons and commas and
    # treats quotes and backslashes specially, so the symbolizer path is held
    # to characters it passes through unchanged.
    PLAIN_PATH = %r{\A[A-Za-z0-9._+/-]+\z}

    # { 'ASAN_OPTIONS' => ..., 'UBSAN_OPTIONS' => ..., 'TSAN_OPTIONS' => ... }
    # for programs compiler built. asan, ubsan and tsan are each a list of
    # name=value options that replace the policy's options of those names.
    def call(asan: [], ubsan: [], tsan: [], compiler: ENV.fetch('ERX_CLANG', 'clang'))
      symbolizer = "external_symbolizer_path=#{symbolizer_path(compiler)}"
      { asan: asan, ubsan: ubsan, tsan: tsan }.to_h do |sanitizer, changes|
        options = parse(POLICY.fetch(sanitizer)).merge(parse(changes))
        [VARIABLES.fetch(sanitizer), [*options.map { |name, value| "#{name}=#{value}" }, symbolizer].join(':')]
      end.freeze
    end

    # The llvm-symbolizer beside compiler, after resolving compiler through
    # PATH and symbolic links.
    def symbolizer_path(compiler)
      path = File.join(File.dirname(File.realpath(locate(compiler))), SYMBOLIZER)
      unless File.file?(path) && File.executable?(path)
        raise Error, "#{SYMBOLIZER} is not installed beside the compiler #{compiler} (looked for #{path}); " \
                     'set ERX_CLANG to the installed LLVM clang (see README.md): sanitizer reports need its ' \
                     "#{SYMBOLIZER}, and the macOS default, atos, can hang"
      end
      raise Error, "#{path} cannot be named in a sanitizer option string" unless path.match?(PLAIN_PATH)

      path
    end

    def parse(options)
      options.to_h do |option|
        raise Error, "#{option.inspect} is not a plain name=value sanitizer option" unless option.match?(OPTION)

        option.split('=', 2)
      end
    end

    def locate(compiler)
      if compiler.include?(File::SEPARATOR)
        return compiler if File.file?(compiler)

        raise Error, "the compiler #{compiler} does not exist, so #{SYMBOLIZER} cannot be located"
      end
      found = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).reject(&:empty?)
                 .map { |directory| File.join(directory, compiler) }
                 .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      found || raise(Error, "cannot find the compiler #{compiler} on PATH to locate #{SYMBOLIZER}; set ERX_CLANG")
    end
    private_class_method :parse, :locate
  end
end
