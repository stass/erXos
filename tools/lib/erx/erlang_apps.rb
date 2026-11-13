# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'error'
require_relative 'generated'
require_relative 'oracle'
require_relative 'serving_set'

module Erx
  # erXos's own Erlang applications, erlang/apps/<application>, compiled into a runtime's
  # OTP copy as lib/<application>/ebin beside kernel and stdlib, where the release takes
  # every application's files from (docs/design.md, the tree layout). Each build starts
  # from an empty ebin, so a module that left the tree leaves the release, and the
  # application file is the .app.src, refused unless it lists exactly the src/ modules
  # compiled, with the modules of erxos/ added to its list, so systools and the code
  # server see what the release holds. An
  # application's generated modules and headers are in the generated tree, at the same
  # paths under build/gen/erlang/apps/<application> (Erx::Generated), and compile with
  # its own.
  class ErlangApps
    # In dependency order, as the release file lists them. A directory of erlang/apps/
    # missing here fails the build, so none is left out of the release unseen.
    APPLICATIONS = %w[erx erx_files erx_uart erx_blk erx_storage erx_memdraw erx_display erx_fb erx_win erx_web erx_net erx_net_client erx_shell erx_code erx_hostlink erx_domain erx_starter erx_web_line erx_session].freeze
    SOURCE = 'erlang/apps'
    # Test-only applications, in test/erlang/apps: the runtime build compiles them into the
    # OTP copy beside the others, so a test image's domain boot script can take one
    # (ReleaseFiles.domain_boot with test: true, ProductionImage's test entry point), and no
    # release lists them, so no other image carries one.
    TEST_ONLY = %w[erx_clock_test erx_echo_test].freeze
    TEST_SOURCE = 'test/erlang/apps'
    # OTP's applications in the tree, whose include/ headers erXos's include_lib reads.
    OTP_LIB = 'otp/lib'
    # Kernel's own error and warning flags (otp/lib/kernel/src/Makefile, otp/make/otp.mk.in)
    # less its documentation warnings, which erXos's modules do not follow, with
    # `+deterministic` so that another checkout builds the same bytes.
    FLAGS = %w[-Werror +debug_info +deterministic +warn_deprecated_catch +warn_obsolete_bool_op].freeze
    DEADLINE = 300

    # The tree's directory of an application, relative to the root.
    def self.source(application) = File.join(TEST_ONLY.include?(application) ? TEST_SOURCE : SOURCE, application)

    # Whether application is one of erXos's own, compiled here, test-only ones included.
    def self.own?(application) = APPLICATIONS.include?(application) || TEST_ONLY.include?(application)

    # The generated tree's directory of an application, relative to the root.
    def self.generated(application) = File.join(Generated::OUTPUT, source(application))

    # An application's modules, relative to the root: src/**/*.erl of its directory in
    # the tree and in the generated tree, which share no path (Generated.ensure refuses a
    # file of the tree at a generated file's path), and erxos/**/*.erl, the modules of an
    # application that also runs outside erXos that only erXos's images hold, such as
    # erx_net's transport and runtime (docs/design-network-stack.md, "Two places, four
    # seams"). Such an application's portable/ directory is for builds outside erXos.
    def self.modules(root:, application:)
      tree, generated = [source(application), generated(application)].map do |directory|
        Dir.glob(%w[src/**/*.erl erxos/**/*.erl], base: File.join(root, directory)).to_h { |path| [path, File.join(directory, path)] }
      end
      # erxos/ after src/, whose behaviours its modules implement, and within each a
      # behaviour, a module declaring callbacks, before the modules that implement it:
      # erlc compiles in this order.
      tree.merge(generated).sort_by do |path, full|
        [path.start_with?('erxos/') ? 1 : 0, behaviour?(File.join(root, full)) ? 0 : 1, path]
      end.map(&:last)
    end

    def self.behaviour?(file) = File.foreach(file).any? { |line| line.start_with?('-callback ') }
    private_class_method :behaviour?

    # An application's module names in two lists, those of its erxos/ directories, in the
    # tree and the generated tree, and the rest, src/'s; a name in both is refused, since
    # one beam would overwrite the other.
    def self.erxos_and_src(application, modules)
      places = [source(application), generated(application)].map { |directory| File.join(directory, 'erxos/') }
      erxos, src = modules.partition { |path| places.any? { |place| path.start_with?(place) } }
                          .map { |paths| paths.map { |path| File.basename(path, '.erl') } }
      twice = erxos & src
      raise Error, "#{application} has modules in both src/ and erxos/: #{twice.join(' ')}" unless twice.empty?

      [erxos, src]
    end

    # The application file's text with its module list replaced by modules. The .app.src
    # lists src/ alone, the modules every build holds, so it is right outside erXos too;
    # erXos's build adds erxos/, and a build outside erXos adds portable/.
    def self.with_modules(text, modules)
      text.sub(/\{modules,\s*\[[^\]]*\]\}/m) { "{modules, [#{modules.join(', ')}]}" }
    end

    # The module list of an application file's text, which names each by its bare atom.
    def self.modules_of(text, label:)
      list = text[/\{modules,\s*\[([^\]]*)\]\}/m, 1] or raise Error, "#{label} lists no modules"
      list.split(',').map(&:strip).reject(&:empty?)
    end

    # erlc's -I flags for every application's include directory under root, those under
    # build/gen ahead of the tree's, relative to root,
    # so one application can include another's headers; a module compiled from the host
    # (ErlangCompile) gets the same. Last, otp/lib, so that include_lib("kernel/include/
    # dist.hrl") reads the tree's header, which erXos may edit, before the oracle's: erlc
    # tries an include_lib path against -I first and only then the compiler's own OTP.
    def self.include_flags(root:)
      generated = APPLICATIONS.map { |application| generated(application) }
      tree = APPLICATIONS.map { |application| source(application) }
      [*generated, *tree].map { |directory| File.join(directory, 'include') }
                         .select { |directory| File.directory?(File.join(root, directory)) }
                         .flat_map { |directory| ['-I', directory] } + ['-I', OTP_LIB]
    end

    # Every file a build compiles or copies for applications, as absolute paths: the
    # sources the release's receipts name for them.
    def self.sources(root:, applications: APPLICATIONS)
      applications.flat_map do |application|
        [*modules(root: root, application: application), File.join(source(application), 'src', "#{application}.app.src")]
          .map { |path| File.join(root, path) }
      end
    end

    # An application's files as a build and the source check read them: the root-relative
    # paths of its modules (see modules), its .app.src text, the module names that file
    # lists, and the names of the modules in erxos/ and in src/.
    Sources = Data.define(:paths, :resource, :listed, :erxos, :src)

    # Refuses a directory of erlang/apps/ or test/erlang/apps/ that the lists above do not
    # name, so none is left out of a build, or out of the check, unseen.
    def self.refuse_unlisted(root:)
      [[SOURCE, APPLICATIONS], [TEST_SOURCE, TEST_ONLY]].each do |directory, listed|
        next unless File.directory?(File.join(root, directory))

        unlisted = Dir.children(File.join(root, directory)).sort - listed
        raise Error, "#{directory} holds applications ErlangApps does not list: #{unlisted.join(' ')}" unless unlisted.empty?
      end
    end

    # Reads an application's sources, refusing an .app.src whose list differs from the
    # src/ modules, in the tree and the generated tree: each module compiled is listed and
    # each one listed exists.
    def self.read_sources(root:, application:)
      resource_path = File.join(root, source(application), 'src', "#{application}.app.src")
      raise Error, "#{source(application)}/src holds no #{application}.app.src" unless File.file?(resource_path)

      paths = modules(root: root, application: application)
      resource = File.read(resource_path)
      listed = modules_of(resource, label: "#{application}.app.src")
      erxos, src = erxos_and_src(application, paths)
      check_modules(application, listed: listed, compiled: src)
      Sources.new(paths: paths, resource: resource, listed: listed, erxos: erxos, src: src)
    end

    # What the source check runs ahead of any build: refuse_unlisted, then read_sources
    # over every application of the lists whose directory is present, so a module missing
    # from an .app.src fails here as it does in a build. The generated tree must be current.
    def self.check_sources(root:)
      refuse_unlisted(root: root)
      [*APPLICATIONS, *TEST_ONLY].select { |application| File.directory?(File.join(root, source(application))) }
                                              .each { |application| read_sources(root: root, application: application) }
    end

    def self.check_modules(application, listed:, compiled:)
      return if listed.sort == compiled.sort

      raise Error, "#{application}.app.src lists #{listed.sort.join(' ')} but #{application}'s src/ modules, in " \
                   "#{source(application)}/src and #{generated(application)}/src, hold #{compiled.sort.join(' ')}"
    end
    private_class_method :check_modules

    def initialize(root:, runner:, erlc:)
      @root = root
      @runner = runner
      @erlc = erlc
    end

    # Compiles every application into otp/lib/<application>/ebin, then holds /tmp's
    # serving set to what the built beams reach (ServingSet).
    def build(otp:)
      self.class.refuse_unlisted(root: @root)

      [*APPLICATIONS, *TEST_ONLY].each { |application| build_application(application, otp: otp) }
      ServingSet.check(runner: @runner, erl: File.join(File.dirname(@erlc), 'erl'),
                       directories: ServingSet.directories(otp: otp), root: @root)
    end

    private

    def build_application(application, otp:)
      sources = self.class.read_sources(root: @root, application: application)
      modules = sources.paths
      ebin = File.join(otp, 'lib', application, 'ebin')
      FileUtils.rm_rf(File.dirname(ebin))
      FileUtils.mkdir_p(ebin)
      # -pa ebin: a module of the application may name another's behaviour, compiled first,
      # of its own or of an application APPLICATIONS lists before it (erx_storage's erx_lfs
      # implements erx_files' erx_fs).
      earlier = APPLICATIONS.take_while { |other| other != application }
                            .flat_map { |other| ['-pa', File.join(otp, 'lib', other, 'ebin')] }
      @runner.run([@erlc, *FLAGS, *includes, *earlier, '-pa', ebin, '-o', ebin, *modules], name: "erlang-app-#{application}",
                                                                   deadline: DEADLINE, chdir: @root, env: Oracle::CLEAN_ERLANG_ENV)
      File.write(File.join(ebin, "#{application}.app"), self.class.with_modules(sources.resource, [*sources.listed, *sources.erxos]))
    end

    # Every application's include directory, so one application can include another's
    # generated headers by name.
    def includes = self.class.include_flags(root: @root)
  end
end
