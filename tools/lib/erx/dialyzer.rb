# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'etc'
require 'fileutils'
require_relative 'asn1_specifications'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'oracle'
require_relative 'runner'
require_relative 'serving_set'

module Erx
  # Dialyzer over erXos's own Erlang, a step of `tools/erx check`: a misuse of a
  # generated type or a call that breaks a contract fails the build instead of
  # surfacing at run time. It is strict: any warning of Dialyzer's default set fails
  # the step.
  #
  # The PLT, Dialyzer's table of the types of the OTP modules erXos's code calls, is
  # built from the tree's own OTP, not the oracle's beams: erXos edits OTP (prim_file's
  # erx_* calls, the erx_untraced spawn option), and a stock PLT reports those uses as
  # errors. `make check` builds no runtime, so the oracle's erlc compiles the tree's
  # sources with debug_info into build/, and the PLT is cached there under the digest
  # of everything it reads.
  class Dialyzer
    # What one Dialyzer or erlc command reads: source files, the directories their
    # includes search and the macros they need defined. Paths are relative to the root.
    SourceSet = Data.define(:files, :includes, :defines) do
      def flags = [*defines.map { |name, value| "-D#{name}=#{value}" }, *includes.flat_map { |dir| ['-I', dir] }]
    end

    OUTPUT = 'build/dialyzer'
    DEADLINE = 900

    # The OTP applications whose types erXos's code reaches, beside erts' preloaded
    # modules.
    PLT_APPLICATIONS = %w[kernel stdlib compiler crypto asn1 public_key ssh].freeze
    PRELOADED = 'otp/erts/preloaded/src'
    GENERATED_PRELOADED = File.join(Generated::OUTPUT, PRELOADED)
    # The macros the applications' Makefiles define on erlc's command line; the values
    # are placeholders, since no type depends on them.
    PLT_DEFINES = { 'CRYPTO_VSN' => '"dialyzer"', 'COMPILER_VSN' => '"dialyzer"' }.freeze
    PUBLIC_KEY = 'otp/lib/public_key'
    # lib/public_key/asn1/Makefile's flags for the ASN.1 compiler.
    ASN1_FLAGS = %w[-bber +der +noobj +asn1config +deterministic].freeze
    # erlc processes compiling the PLT's sources at once; each takes about 260 MB.
    COMPILE_JOBS = [Etc.nprocessors, 8].min

    def initialize(root:, runner:, erlc:)
      @root = root
      @runner = runner
      @erlc = erlc
      @bin = File.dirname(erlc)
    end

    # The step: the tree's own Erlang against the tree's OTP.
    def check = analyse(plt: plt(plt_set), set: analysis_set)

    # The PLT of set, built unless build/ holds one of the same inputs; answers its path.
    # Building one deletes the PLT of other inputs. Dialyzer builds a PLT only from
    # beams, and warns there only of what the PLT's own modules call outside it, which
    # is not erXos's code, so that warning is off.
    def plt(set)
      path = File.join(output, "plt-#{digest(set)}.plt")
      return path if File.file?(path)

      ebin = File.join(output, 'ebin')
      FileUtils.rm_rf(ebin)
      FileUtils.mkdir_p(ebin)
      compile(set, ebin: ebin)
      partial = "#{path}.partial"
      dialyze(['--build_plt', '-Wno_unknown', '--output_plt', partial, ebin], name: 'dialyzer-plt')
      FileUtils.rm_rf(ebin)
      Dir.glob(File.join(output, 'plt-*')).each { |stale| File.delete(stale) unless stale == partial }
      File.rename(partial, path)
      path
    end

    # Analyses set's sources against plt; raises Error naming the log on any warning.
    def analyse(plt:, set:)
      dialyze(['--plt', plt, '--no_check_plt', '--src', *set.flags, *set.files], name: 'dialyzer')
    end

    # The tree's OTP: each application's src, the sources public_key's build generates
    # (public_key_sources) and the preloaded modules analysis_set does not hold.
    def plt_set
      applications = PLT_APPLICATIONS.flat_map { |application| Dir.glob("otp/lib/#{application}/src/*.erl", base: @root) }
      own = own_preloaded.map { |file| File.basename(file) }
      preloaded = Dir.glob("#{PRELOADED}/*.erl", base: @root).reject { |file| own.include?(File.basename(file)) }
      includes = [*%w[kernel stdlib public_key].map { |application| "otp/lib/#{application}/include" },
                  'otp/lib/kernel/src', public_key_output, File.join(ErlangApps.generated('erx'), 'include'),
                  ErlangApps::OTP_LIB]
      SourceSet.new(files: [*applications, *public_key_sources, *preloaded].sort, includes: includes, defines: PLT_DEFINES)
    end

    # erXos's applications and test applications, the erx_* and generated preloaded
    # modules, and a stand-in for erx_files's derived module (serving_stand_in).
    def analysis_set
      modules = [*ErlangApps::APPLICATIONS, *ErlangApps::TEST_ONLY]
                .flat_map { |application| ErlangApps.modules(root: @root, application: application) }
                .map { |file| file.delete_prefix("#{@root}/") }
      includes = ErlangApps.include_flags(root: @root).each_slice(2).map(&:last) + %w[otp/lib/kernel/include otp/lib/kernel/src]
      SourceSet.new(files: [*modules, *own_preloaded, serving_stand_in], includes: includes, defines: {})
    end

    private

    # Compiles set's sources into ebin, COMPILE_JOBS erlc processes at once. Warnings
    # are off: the sources are OTP's, which Dialyzer reads here for types only.
    def compile(set, ebin:)
      slices = set.files.each_slice((set.files.size.to_f / COMPILE_JOBS).ceil)
      failures = slices.with_index.map do |files, index|
        Thread.new do
          run(@erlc, '-W0', '+debug_info', '-o', ebin, *set.flags, *files, name: "dialyzer-plt-erlc-#{index}", chdir: @root)
          nil
        rescue Error => error
          error
        end
      end.map(&:value).compact
      raise failures.first unless failures.empty?
    end

    # Runs Dialyzer, strict: a warning (exit status 2) fails it like an error.
    def dialyze(arguments, name:)
      run(File.join(@bin, 'dialyzer'), *arguments, name: name, chdir: @root)
    rescue CommandError => error
      raise Error, "#{name}: Dialyzer reported problems; log: #{error.result.fetch('log')}"
    end

    def run(*argv, name:, chdir:)
      FileUtils.mkdir_p(output)
      @runner.run(argv, name: name, deadline: DEADLINE, chdir: chdir, env: Oracle::CLEAN_ERLANG_ENV)
    end

    # The erx_* modules of erts' preloaded set and the generated ones.
    def own_preloaded
      [*Dir.glob("#{PRELOADED}/erx_*.erl", base: @root), *Dir.glob("#{GENERATED_PRELOADED}/*.erl", base: @root)].sort
    end

    # The runtime build derives erx_ramfs_serving from its beams (ServingSet), and
    # `make check` builds none. The stand-in is ServingSet's own rendering, with the
    # real module's export and spec, over the seeds instead of the derived list.
    def serving_stand_in
      path = File.join(OUTPUT, "#{ServingSet::MODULE}.erl")
      FileUtils.mkdir_p(output)
      File.write(File.join(@root, path), ServingSet.render(ServingSet::SEEDS))
      path
    end

    # Writes the sources public_key's Makefiles generate into public_key_output, afresh
    # each run since that takes about a second: the ASN.1 modules and their headers
    # (lib/public_key/asn1/Makefile) and pubkey_moduli.hrl (lib/public_key/src/Makefile).
    # Answers the modules' paths.
    def public_key_sources
      generated = File.join(@root, public_key_output)
      FileUtils.rm_rf(generated)
      FileUtils.mkdir_p(generated)
      asn1 = File.join(@root, PUBLIC_KEY, 'asn1')
      names = Asn1Specifications.modules(asn1)
      specifications = names.map { |name| File.basename(Asn1Specifications.sources(asn1, name).first) }
      run(@erlc, *ASN1_FLAGS, '-o', generated, *specifications, name: 'dialyzer-asn1', chdir: asn1)
      priv = File.join(@root, PUBLIC_KEY, 'priv')
      run(File.join(@bin, 'escript'), File.join(priv, 'convert.escript'), File.join(priv, 'moduli'),
          File.join(generated, 'pubkey_moduli.hrl'), name: 'dialyzer-moduli', chdir: @root)
      names.map { |name| File.join(public_key_output, "#{name}.erl") }
    end

    def public_key_output = File.join(OUTPUT, 'public_key')

    # The digest of what a PLT of set reads: its flags, its files and every header in
    # its include directories. The oracle's erlc and Dialyzer are pinned and verified
    # (Oracle#with_runtime), so they are not part of it.
    def digest(set)
      headers = set.includes.flat_map { |dir| Dir.glob("#{dir}/**/*.hrl", base: @root) }
      lines = [*set.files, *headers].sort.map { |file| "#{file}\0#{Digest::SHA256.file(File.join(@root, file)).hexdigest}" }
      Digest::SHA256.hexdigest([*set.flags, *lines].join("\n"))
    end

    def output = File.join(@root, OUTPUT)
  end
end
