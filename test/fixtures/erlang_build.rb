# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/erlang_apps'
require_relative '../../tools/lib/erx/oracle'
# build/gen brought up to date at process entry (Erx::Generated, "Who calls ensure").
require_relative 'generated_tree'

# How a host test compiles erXos's Erlang for EUnit on stock's compiler (ERX_ERLC, which
# make check supplies): every module of each application it names, read as the build
# reads them (Erx::ErlangApps.read_sources: src/ and erxos/, in the tree and in
# build/gen, refused unless the .app.src lists them), with the build's flags and include
# directories, then its own test modules. A test names applications, not modules, so a
# module an application gains is compiled without the test changing, and one it loses
# fails the compile with the application's diagnostic instead of an `undef` at run time.
#
# The applications are compiled once per test process and set of applications, into a
# directory removed at exit; each compile copies their beams into the test's directory
# and compiles the test modules, and any source given replacement text, over them, so a
# seeded fault recompiles one module, not the applications.
module ErlangBuild
  ROOT = File.expand_path('../..', __dir__)
  # Every application ErlangApps knows, in its dependency order, so an application's
  # behaviours are compiled before the modules of a later one that implement them.
  ORDER = [*Erx::ErlangApps::APPLICATIONS, *Erx::ErlangApps::TEST_ONLY].freeze
  # Test modules are not held to the build's deprecation warnings; -Werror still holds.
  TEST_FLAGS = %w[-Werror +debug_info].freeze
  REPLACED_FLAGS = (Erx::ErlangApps::FLAGS - %w[-Werror]).freeze
  DEADLINE = 300

  class Error < Erx::Error; end

  @cache = {}
  @lock = Mutex.new

  # Compiles into work, an existing directory: each application's modules, then tests,
  # root-relative paths of test modules compiled in order (a test-only stub of an
  # application's module compiled here replaces that module's beam). replaced maps a
  # root-relative source path, of an application's module (as ErlangApps.modules spells
  # it) or of a test module, to the text compiled in its place. includes: further
  # root-relative -I directories. Raises Error with erlc's output on a failed compile.
  def self.compile(work, applications:, tests: [], replaced: {}, includes: [])
    unknown = replaced.keys - tests - with_dependencies(applications).flat_map { |application| modules(application) }
    raise Error, "replaced names no module compiled here: #{unknown.join(' ')}" unless unknown.empty?

    FileUtils.cp(Dir.glob(File.join(applications_beams(applications), '*.beam')), work)
    # A replacement is written into work, so the directory of the file it replaces is
    # where its quoted includes are still found.
    beside = replaced.keys.flat_map { |source| ['-I', File.dirname(source)] }
    # A replaced application module is a seeded fault or a stand-in, which may leave a
    # variable or function unused: the build's flags less -Werror.
    own = replaced.keys - tests
    erlc(work, [*REPLACED_FLAGS, *beside], own.map { |source| written(work, source, replaced) }) unless own.empty?
    flags = [*TEST_FLAGS, *beside, *includes.flat_map { |directory| ['-I', directory] }]
    erlc(work, flags, tests.map { |source| written(work, source, replaced) }) unless tests.empty?
    work
  end

  # An application's modules, root-relative, as the build compiles them.
  def self.modules(application) = Erx::ErlangApps.read_sources(root: ROOT, application: application).paths

  # applications and every application of ORDER their .app.src files declare, directly or
  # through another: a test names what it exercises, and what that calls comes with it.
  def self.with_dependencies(applications)
    grown = applications | applications.flat_map { |application| dependencies(application) }
    grown.sort == applications.sort ? applications : with_dependencies(grown)
  end
  
  def self.dependencies(application)
    text = Erx::ErlangApps.read_sources(root: ROOT, application: application).resource
    list = text[/\{applications,\s*\[([^\]]*)\]\}/m, 1] or raise Error, "#{application}.app.src lists no applications"
    list.split(',').map(&:strip) & ORDER
  end

  # The directory holding the beams of applications, compiled on first use.
  def self.applications_beams(applications)
    unknown = applications - ORDER
    raise Error, "ErlangApps lists no application #{unknown.join(' ')}" unless unknown.empty?

    ordered = ORDER & with_dependencies(applications)
    @lock.synchronize { @cache[ordered] ||= compile_applications(ordered) }
  end

  def self.compile_applications(applications)
    Erx::Generated.ensure(root: ROOT)
    Dir.mktmpdir('erx-erlang-build').tap do |beams|
      at_exit { FileUtils.rm_rf(beams) }
      applications.each { |application| erlc(beams, Erx::ErlangApps::FLAGS, modules(application)) }
    end
  end

  # A source as erlc reads it: the tree's or build/gen's file, or its replacement text
  # written into work under its own name.
  def self.written(work, source, replaced)
    return source unless replaced.key?(source)

    File.join(work, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
  end

  # -pa out: a module may name a behaviour compiled ahead of it into the same directory.
  def self.erlc(out, flags, sources)
    command = ['gtimeout', '-k', '10', DEADLINE.to_s, ENV.fetch('ERX_ERLC'), *flags,
               *Erx::ErlangApps.include_flags(root: ROOT), '-pa', out, '-o', out, *sources]
    output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, *command, chdir: ROOT, stdin_data: '')
    raise Error, "erlc failed (#{status}):\n#{output}" unless status.success?
  end
  private_class_method :modules, :with_dependencies, :dependencies, :applications_beams, :compile_applications, :written, :erlc
end
