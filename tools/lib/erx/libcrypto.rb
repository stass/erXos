# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'
require_relative 'bounded_file'
require_relative 'build_memo'
require_relative 'error'
require_relative 'musl'
require_relative 'runner'

module Erx
  # OpenSSL's libcrypto.a for erXos's erxos-aarch64 target (docs/design-crypto.md,
  # "Building OpenSSL"): the one way into OpenSSL's inherited Configure, its Perl
  # generators and its make. The source tree is only read; Configure runs in the build
  # directory, which holds every file Configure and make write.
  #
  # Configure and make see only the environment ENVIRONMENT names, so nothing of the
  # caller's (CFLAGS, CPPDEFINES, OPENSSL_LOCAL_CONFIG_DIR, PERL5OPT, MAKEFLAGS) changes
  # what is built. The archive holds no path of the build host: the compiler is named
  # without its directory, the sysroot relative to the build directory, and the build
  # date is SOURCE_DATE_EPOCH's, as the tree's other builds pin it.
  #
  # What the archive references from outside it is checked after every build (Imports).
  class Libcrypto
    TARGET = 'erxos-aarch64'
    TARGET_FILE = 'config/openssl/erxos-aarch64.conf'
    # The configuration, each option's reason in the design's table.
    OPTIONS = %w[--with-rand-seed=getrandom
                 no-shared no-module no-dso no-engine no-async no-sock
                 no-autoload-config no-ui-console no-apps no-tests no-docs
                 no-legacy no-quic no-http].freeze
    ARCHIVE = 'libcrypto.a'
    # The caller's variables Configure, Perl and make are given; every other one is unset.
    PASSED = %w[HOME TMPDIR].freeze
    FIXED = { 'LC_ALL' => 'C', 'SOURCE_DATE_EPOCH' => '0' }.freeze
    # What Configure reads besides the target file and its options: the tree's own
    # configurations, every build.info, and the Perl it loads (util/perl's modules, the
    # template engine under external/perl and util/dofile.pl), whose change leaves the
    # configuration stale.
    CONFIGURE_INPUTS = %w[Configure VERSION.dat configdata.pm.in Configurations/**/* **/build.info
                          util/perl/**/* util/dofile.pl external/perl/**/*].freeze
    # The file in a configured directory that holds its configuration's key.
    CONFIGURATION_KEY_FILE = '.erx-configuration-key'
    DEADLINES = { configure: 300, make: 1_800, nm: 120 }.freeze
    # A bound on llvm-nm's listing of the archive, which is a few MiB.
    NM_BYTES = 64 * 1024 * 1024

    # What the archive's members reference from outside it, checked after every build:
    # the design's invariants as facts of its symbols, over the listing of `llvm-nm -A`.
    # rand_unix.c's syscall_random calls musl's getrandom directly, and rand_unix.c
    # compiles no other seed method: no device read, no EGD socket, no CPU source (K2);
    # armcap.c reads the kernel's feature words through getauxval and compiles no SIGILL
    # probe (K4); and no member looks getentropy up weakly, loads code or opens a socket
    # (K2 and K5: no-dso and no-sock).
    module Imports
      Rule = Data.define(:member, :strong, :absent)
      RULES = [
        Rule.new(member: 'libdefault-lib-rand_unix.o', strong: %w[getrandom],
                 absent: %w[open read poll select shmat RAND_query_egd_bytes
                            ossl_prov_acquire_entropy_from_cpu ossl_prov_acquire_entropy_from_tsc]),
        Rule.new(member: 'libcrypto-lib-armcap.o', strong: %w[getauxval], absent: %w[sigaction sigsetjmp siglongjmp])
      ].freeze
      NEVER = %w[getentropy dlopen dlsym socket connect].freeze
      # One line of `llvm-nm -A`: the file (archive:member, or an object), an address for
      # a defined symbol, the symbol's type letter and its name.
      LINE = /\A(?<file>.+?):\s+(?:\h+\s+)?(?<type>[A-Za-z?-])\s+(?<name>\S+)\z/

      module_function

      # The members' symbols in listing, as { member => { name => type } }. A line of
      # another shape (a blank line, a header) names no symbol and is skipped.
      def members(listing)
        listing.each_line(chomp: true).each_with_object({}) do |line, found|
          match = LINE.match(line)
          next unless match

          member = File.basename(match[:file].split(':').last)
          (found[member] ||= {})[match[:name]] = match[:type]
        end
      end

      # The rules listing breaks, one sentence each; empty when it keeps them all.
      def violations(listing)
        symbols = members(listing)
        never = symbols.flat_map do |member, held|
          NEVER.select { |name| held.key?(name) }.map { |name| "#{member} references #{name} (#{held.fetch(name)})" }
        end
        never + RULES.flat_map { |rule| rule_violations(rule, symbols) }
      end

      def rule_violations(rule, symbols)
        held = symbols[rule.member]
        return ["#{rule.member} is not in the archive"] unless held

        missing = rule.strong.reject { |name| held[name] == 'U' }
                      .map { |name| "#{rule.member} does not reference #{name} strongly" }
        present = rule.absent.select { |name| held.key?(name) }
                          .map { |name| "#{rule.member} references #{name} (#{held.fetch(name)})" }
        missing + present
      end
      private_class_method :rule_violations
    end

    # Where `tools/erx build openssl` builds: musl, its headers as one tree, and OpenSSL.
    BASE = 'build/openssl'

    # A sysroot for a build of OpenSSL alone, under root's BASE: erXos's musl built, and
    # its headers merged into the sysroot's include/. Returns the sysroot. A runtime's
    # build passes its own sysroot instead, which holds the same headers.
    def self.sysroot(root:, runner:, compiler:, jobs: 4)
      musl = Musl.new(root: root, runner: runner, compiler: compiler)
      built = File.join(root, BASE, 'musl')
      musl.build(directory: built, jobs: jobs)
      sysroot = File.join(root, BASE, 'sysroot')
      musl.merge_headers(directory: built, into: File.join(sysroot, 'include'))
      sysroot
    end

    # compiler is the clang every erXos build uses (ERX_CLANG); llvm-ar, llvm-ranlib and
    # llvm-nm are found beside it. source is the tree Configure reads, which a test may
    # replace with a copy holding a seeded fault.
    def initialize(root:, runner:, compiler:, source: File.join(root, 'openssl'))
      raise Error, 'set ERX_CLANG to the installed LLVM clang' if compiler.to_s.empty?

      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @source = File.expand_path(source)
      @tools = File.dirname(compiler)
    end

    # Configures directory for TARGET when its configuration changed, makes target there
    # (the archive, or one of its objects for a test), and checks the imports of what it
    # made; returns its path. sysroot's include/ holds musl's headers as one tree
    # (Musl#merge_headers).
    def build(directory:, sysroot:, jobs: 4, target: ARCHIVE)
      environment = environment(directory: directory, sysroot: sysroot)
      configure(directory: directory, environment: environment)
      # OpenSSL's own build_libs, for target alone: the headers Configure's generators
      # make, which no object names, then depend, which writes the header dependencies
      # the last build's compiles recorded into the Makefile, so an edited header
      # rebuilds what includes it.
      make(directory: directory, targets: ['build_generated'], jobs: jobs, environment: environment)
      make(directory: directory, targets: ['depend'], jobs: 1, environment: environment)
      make(directory: directory, targets: [target], jobs: jobs, environment: environment)
      made = File.join(directory, target)
      check(made)
      made
    end

    # Raises unless the archive or object at path keeps Imports' rules.
    def check(path)
      result = @runner.run([File.join(@tools, 'llvm-nm'), '-A', path], name: 'openssl-nm', deadline: DEADLINES.fetch(:nm),
                                                                       output_limit: NM_BYTES)
      problems = Imports.violations(BoundedFile.read(result.fetch('log'), maximum: NM_BYTES))
      raise Error, "#{path} breaks libcrypto's import rules: #{problems.join('; ')}" unless problems.empty?
    end

    private

    # Configure runs again, in an emptied directory, when the configuration's key
    # (configuration_key) differs from the one the directory was configured for, so a
    # configuration is never reused for inputs it was not made from. Source files are
    # make's to judge.
    def configure(directory:, environment:)
      command = ['perl', File.join(@source, 'Configure'), TARGET, "--config=#{target_file}", *OPTIONS]
      key = configuration_key(command, environment)
      key_file = File.join(directory, CONFIGURATION_KEY_FILE)
      return if File.file?(key_file) && File.read(key_file) == key

      FileUtils.rm_rf(directory)
      FileUtils.mkdir_p(directory)
      @runner.run(command, name: 'openssl-configure', deadline: DEADLINES.fetch(:configure), chdir: directory,
                           env: environment)
      File.write(key_file, key)
    rescue CommandError => e
      raise Error, "OpenSSL's Configure failed for #{TARGET} on #{@source}; log: #{e.result.fetch('log')}"
    end

    def make(directory:, targets:, jobs:, environment:)
      @runner.run(['gmake', "-j#{jobs}", *targets], name: 'openssl-make', deadline: DEADLINES.fetch(:make),
                                                    chdir: directory, env: environment)
    end

    def target_file = File.join(@root, TARGET_FILE)

    # What a configuration follows from, as a BuildMemo key: Configure's command (the
    # source tree, the target, the target file's path and the options), the variables it
    # sees, the target file's bytes, the compiler by identity (a new clang rebuilds every
    # object, which make alone would not do) and the bytes of every input CONFIGURE_INPUTS
    # names. perl, gmake and LLVM's archivers are named only by the PATH they are found on.
    def configuration_key(command, environment)
      inputs = Dir.glob(CONFIGURE_INPUTS, base: @source).sort.select { |path| File.file?(File.join(@source, path)) }
      BuildMemo.key('command' => command, 'environment' => environment.compact, 'target' => digest(target_file),
                    'compiler' => BuildMemo.program_identity(@compiler),
                    'inputs' => inputs.to_h { |path| [path, digest(File.join(@source, path))] })
    end

    def digest(path) = Digest::SHA256.file(path).hexdigest

    # The whole environment of Configure and make: the caller's variables unset but for
    # PASSED, FIXED's, PATH with the compiler's directory first, and what the target file
    # reads. The sysroot is named relative to directory, where Configure and make run.
    def environment(directory:, sysroot:)
      relative = Pathname.new(File.expand_path(sysroot)).relative_path_from(Pathname.new(File.expand_path(directory)))
      ENV.keys.to_h { |name| [name, nil] }
         .merge(ENV.to_h.slice(*PASSED), FIXED)
         .merge('PATH' => [@tools, ENV.fetch('PATH', '')].join(File::PATH_SEPARATOR),
                'ERX_CC' => File.basename(@compiler), 'ERX_SYSROOT' => relative.to_s)
    end
  end
end
