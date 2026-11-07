# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'error'
require_relative 'oracle'
require_relative 'serving_set'

module Erx
  # erXos's own Erlang applications, erlang/apps/<application>, compiled into a runtime's
  # OTP copy as lib/<application>/ebin beside kernel and stdlib, where the release takes
  # every application's files from (docs/design.md, the tree layout). Each build starts
  # from an empty ebin, so a module that left the tree leaves the release, and the
  # application file is the .app.src as written, refused unless it lists exactly the
  # modules compiled, so systools and the code server see what the release holds.
  class ErlangApps
    # In dependency order, as the release file lists them. A directory of erlang/apps/
    # missing here fails the build, so none is left out of the release unseen.
    APPLICATIONS = %w[erx erx_files erx_uart erx_blk erx_shell erx_hostlink].freeze
    SOURCE = 'erlang/apps'
    # Kernel's own error and warning flags (otp/lib/kernel/src/Makefile, otp/make/otp.mk.in)
    # less its documentation warnings, which erXos's modules do not follow, with
    # `+deterministic` so that another checkout builds the same bytes.
    FLAGS = %w[-Werror +debug_info +deterministic +warn_deprecated_catch +warn_obsolete_bool_op].freeze
    DEADLINE = 300

    # The tree's directory of an application, relative to the root.
    def self.source(application) = File.join(SOURCE, application)

    # The module list of an application file's text, which names each by its bare atom.
    def self.modules_of(text, label:)
      list = text[/\{modules,\s*\[([^\]]*)\]\}/m, 1] or raise Error, "#{label} lists no modules"
      list.split(',').map(&:strip).reject(&:empty?)
    end

    # Every file a build compiles or copies, as absolute paths: the sources the release's
    # receipts name for these applications.
    def self.sources(root:)
      APPLICATIONS.flat_map do |application|
        directory = File.join(root, source(application))
        Dir.glob('src/**/*.{erl,app.src}', base: directory).sort.map { |path| File.join(directory, path) }
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
      unlisted = Dir.children(File.join(@root, SOURCE)).sort - APPLICATIONS
      raise Error, "#{SOURCE} holds applications ErlangApps does not list: #{unlisted.join(' ')}" unless unlisted.empty?

      APPLICATIONS.each { |application| build_application(application, otp: otp) }
      ServingSet.check(runner: @runner, erl: File.join(File.dirname(@erlc), 'erl'),
                       directories: ServingSet.directories(otp: otp), root: @root)
    end

    private

    def build_application(application, otp:)
      source = self.class.source(application)
      modules = Dir.glob('src/**/*.erl', base: File.join(@root, source)).sort.map { |path| File.join(source, path) }
      resource = File.read(File.join(@root, source, 'src', "#{application}.app.src"))
      check_modules(application, listed: self.class.modules_of(resource, label: "#{application}.app.src"),
                                 compiled: modules.map { |path| File.basename(path, '.erl') })
      ebin = File.join(otp, 'lib', application, 'ebin')
      FileUtils.rm_rf(File.dirname(ebin))
      FileUtils.mkdir_p(ebin)
      # -pa ebin: a module of the application may name another's behaviour, compiled first.
      @runner.run([@erlc, *FLAGS, *includes, '-pa', ebin, '-o', ebin, *modules], name: "erlang-app-#{application}",
                                                                   deadline: DEADLINE, chdir: @root, env: Oracle::CLEAN_ERLANG_ENV)
      File.write(File.join(ebin, "#{application}.app"), resource)
    end

    # Every application's include directory, so one application can include another's
    # generated headers by name.
    def includes
      APPLICATIONS.map { |application| File.join(self.class.source(application), 'include') }
                  .select { |directory| File.directory?(File.join(@root, directory)) }
                  .flat_map { |directory| ['-I', directory] }
    end

    def check_modules(application, listed:, compiled:)
      return if listed.sort == compiled.sort

      raise Error, "#{application}.app.src lists #{listed.sort.join(' ')} but #{SOURCE}/#{application}/src holds " \
                   "#{compiled.sort.join(' ')}"
    end
  end
end
