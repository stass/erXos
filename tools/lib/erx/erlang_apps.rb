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
    APPLICATIONS = %w[erx erx_files erx_uart erx_blk erx_storage erx_web erx_net erx_net_client erx_shell erx_code erx_hostlink erx_domain erx_session].freeze
    # Applications of another domain's image, written and tested on the host ahead of
    # the milestone that builds that image (docs/plan.md, "Critical path and parallel
    # tracks"): the host tests compile them, and no release holds them yet.
    UNRELEASED = %w[erx_display].freeze
    SOURCE = 'erlang/apps'
    # Test-only applications, in test/erlang/apps: the runtime build compiles them into the
    # OTP copy beside the others, so a test image's domain boot script can take one
    # (ReleaseFiles.domain_boot with test: true, ProductionImage's test entry point), and no
    # release lists them, so no other image carries one.
    TEST_ONLY = %w[erx_echo_test].freeze
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
      # erxos/ after src/, whose behaviours its modules implement: erlc compiles in this order.
      tree.merge(generated).sort_by { |path, _| [path.start_with?('erxos/') ? 1 : 0, path] }.map(&:last)
    end

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

    def initialize(root:, runner:, erlc:)
      @root = root
      @runner = runner
      @erlc = erlc
    end

    # Compiles every application into otp/lib/<application>/ebin, then holds /tmp's
    # serving set to what the built beams reach (ServingSet).
    def build(otp:)
      unlisted = Dir.children(File.join(@root, SOURCE)).sort - APPLICATIONS - UNRELEASED
      raise Error, "#{SOURCE} holds applications ErlangApps does not list: #{unlisted.join(' ')}" unless unlisted.empty?
      tests = Dir.children(File.join(@root, TEST_SOURCE)).sort - TEST_ONLY
      raise Error, "#{TEST_SOURCE} holds applications ErlangApps does not list: #{tests.join(' ')}" unless tests.empty?

      [*APPLICATIONS, *TEST_ONLY].each { |application| build_application(application, otp: otp) }
      ServingSet.check(runner: @runner, erl: File.join(File.dirname(@erlc), 'erl'),
                       directories: ServingSet.directories(otp: otp), root: @root)
    end

    private

    def build_application(application, otp:)
      source = self.class.source(application)
      modules = self.class.modules(root: @root, application: application)
      resource = File.read(File.join(@root, source, 'src', "#{application}.app.src"))
      listed = self.class.modules_of(resource, label: "#{application}.app.src")
      erxos, src = self.class.erxos_and_src(application, modules)
      check_modules(application, listed: listed, compiled: src)
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
      File.write(File.join(ebin, "#{application}.app"), self.class.with_modules(resource, [*listed, *erxos]))
    end

    # Every application's include directory, so one application can include another's
    # generated headers by name.
    def includes = self.class.include_flags(root: @root)

    def check_modules(application, listed:, compiled:)
      return if listed.sort == compiled.sort

      raise Error, "#{application}.app.src lists #{listed.sort.join(' ')} but #{application}'s src/ modules, in " \
                   "#{self.class.source(application)}/src and #{self.class.generated(application)}/src, hold " \
                   "#{compiled.sort.join(' ')}"
    end
  end
end
