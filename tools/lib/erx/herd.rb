# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # herd7, the weak-memory simulator `make check-litmus` runs (tools/lib/erx/litmus.rb):
  # built for the development host from the pinned herdtools7 release (deps.lock, id
  # `herdtools7`) into build/herdtools7, and run as a subprocess by argument vector,
  # never linked. OCaml, dune, menhir and zarith come from the host (Homebrew on macOS);
  # opam and herdtools7's own Makefile and shell scripts never run.
  module Herd
    SOURCE_ID = 'herdtools7'
    OUTPUT = 'build/herdtools7'
    STAMP = 'build.json'
    # Inside OUTPUT: the program, and herd7's library of models (aarch64.cat, rc11.cat
    # and the files they include), which herdtools7 installs as share/herdtools7/herd.
    PROGRAM = 'bin/herd7'
    LIBRARY = 'share/herdtools7/herd'

    class MissingBuild < Error; end
    class StaleBuild < Error; end

    # A built herd7: the program and the directory its models are read from.
    Tool = Data.define(:program, :libdir)

    module_function

    # The lock entry for herdtools7, read whole and checked by DependencySchema.
    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    # The built herd7, refused unless its build record names deps.lock's pin and
    # this file's recipe, so a program built from another pin or recipe is never run.
    def locate(root:)
      output = File.join(File.expand_path(root), OUTPUT)
      tool = Tool.new(program: File.join(output, PROGRAM), libdir: File.join(output, LIBRARY))
      stamp_path = File.join(output, STAMP)
      unless File.file?(tool.program) && File.directory?(tool.libdir) && File.file?(stamp_path)
        raise MissingBuild, "herd7 is not built in #{output}; run tools/erx build herd7"
      end

      stamp = begin
        JsonInput.parse(BoundedFile.read(stamp_path, maximum: 65_536), max_bytes: 65_536, label: 'herd7 build record')
      rescue JsonInput::Unsupported
        raise
      rescue Error => e
        raise StaleBuild, "herd7 in #{output} has an unreadable build record (#{e.message}); run tools/erx build herd7"
      end
      unless stamp.is_a?(Hash) && stamp['source'] == source_record(root: root) && stamp['recipe'] == Build::RECIPE
        raise StaleBuild, "herd7 in #{output} was built from another source or recipe; run tools/erx build herd7"
      end

      tool
    end

    # An OCaml string literal holding text, which must be printable ASCII.
    def ocaml_string(text)
      raise Error, "herd7 build path is not printable ASCII: #{text.inspect}" unless /\A[\x20-\x7e]*\z/.match?(text)

      %("#{text.gsub(/[\\"]/) { |char| "\\#{char}" }}")
    end

    # Builds herd7 for the host from the fetched release into build/herdtools7.
    #
    # The release's Makefile would run version-gen.sh, which asks git for a revision,
    # and its install script; instead this writes the one generated module,
    # Version.ml, itself, and copies the two outputs. dune builds only herd7 and the
    # libraries it links, out of the copied tree, with its shared cache off.
    #
    # What of the release runs: dune's own actions in the dune files of herd7's
    # dependency closure (copies and echoes at 7.58), ocamllex, menhir and the
    # compiler. Bumping the pin means reviewing the actions reachable from
    # herd/herd.exe again, since check-litmus builds a new pin without asking.
    #
    # As for fsimg, the build record names the pin and the recipe, not the host
    # compiler, and the built program is trusted as the development host's own
    # files are.
    class Build
      # The recipe is this file: a change to it makes an older build stale.
      RECIPE = Digest::SHA256.file(__FILE__).hexdigest.freeze
      DEADLINE = 1800

      def initialize(root:, runner:, jobs: 4)
        @root = File.expand_path(root)
        @runner = runner
        @jobs = jobs
      end

      def call
        source = Herd.source_record(root: @root)
        tree = Dependencies.new(root: @root, runner: @runner).fetched_tree(SOURCE_ID)
        check_release(tree, version: source.fetch('version'))
        ocaml_lib = ocaml_library
        build = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build'))
        Dir.mktmpdir('.herdtools7-', build) do |work|
          copy = File.join(work, 'source')
          objects = File.join(work, 'objects')
          output = File.join(work, 'out')
          FileUtils.cp_r(tree, copy)
          File.write(File.join(copy, 'Version.ml'), version_module(source.fetch('version')))
          @runner.run(['dune', 'build', '--root', copy, '--build-dir', objects,
                       '--profile', 'release', '--cache', 'disabled', '-j', @jobs.to_s, './herd/herd.exe'],
                      name: 'herd7-dune', deadline: DEADLINE, chdir: copy,
                      env: dune_environment(ocaml_lib, findlib: File.join(work, 'findlib.conf')))
          install(copy, objects: objects, output: output)
          stamp = { 'source' => source, 'recipe' => RECIPE }
          File.write(File.join(output, STAMP), "#{JSON.pretty_generate(stamp)}\n")
          publish(output)
        end
        Herd.locate(root: @root)
      end

      private

      # The release says which version it is; it must be the one deps.lock pins.
      def check_release(tree, version:)
        found = BoundedFile.read(File.join(tree, 'VERSION.txt'), maximum: 64).strip
        raise Error, "herdtools7 tree is version #{found.inspect}, not deps.lock's #{version}" unless found == version
      end

      # Where dune finds OCaml's libraries and the linker finds GMP, which zarith
      # links: the compiler's library directory and its parent, where Homebrew
      # installs menhirLib and libgmp. A findlib configuration of this build's own
      # names both, so no ocamlfind on PATH is asked, and the OCAMLPATH, OCAMLPARAM
      # and OCAMLFIND_TOOLCHAIN of the developer's shell are unset, so the build
      # does not depend on them. Writes the configuration to findlib.
      def dune_environment(ocaml_lib, findlib:)
        host_lib = File.dirname(ocaml_lib)
        File.write(findlib, "path = #{Herd.ocaml_string("#{ocaml_lib}:#{host_lib}")}\n")
        { 'OCAMLFIND_CONF' => findlib, 'LIBRARY_PATH' => host_lib,
          'OCAMLPATH' => nil, 'OCAMLPARAM' => nil, 'OCAMLFIND_TOOLCHAIN' => nil }
      end

      # The host compiler's library directory, as `ocamlc -where` prints it; a
      # colon would split the findlib search path, so it is refused.
      def ocaml_library
        record = @runner.run(%w[ocamlc -where], name: 'herd7-ocamlc', deadline: 60)
        where = BoundedFile.read(record.fetch('log'), maximum: 4096).strip
        unless where.start_with?('/') && !where.include?(':') && File.directory?(where)
          raise Error, "ocamlc -where printed no usable library directory: #{where.inspect}"
        end

        where
      rescue CommandError => e
        raise Error, "OCaml is not installed (#{e.message}); install ocaml, dune, menhir and ocaml-zarith with Homebrew"
      end

      # What version-gen.sh writes: the release, no git revision, and the library
      # directory herd7 searches by default, the published one.
      def version_module(version)
        libdir = File.join(@root, OUTPUT, 'share/herdtools7')
        <<~OCAML
          (* GENERATED, DO NOT EDIT *)
          let version = #{Herd.ocaml_string(version)}
          let rev = "exported"
          let libdir = #{Herd.ocaml_string("#{libdir}/")}
        OCAML
      end

      def install(copy, objects:, output:)
        program = File.join(output, PROGRAM)
        FileUtils.mkdir_p(File.dirname(program))
        FileUtils.cp(File.join(objects, 'default/herd/herd.exe'), program)
        FileUtils.mkdir_p(File.dirname(File.join(output, LIBRARY)))
        FileUtils.cp_r(File.join(copy, 'herd/libdir'), File.join(output, LIBRARY))
      end

      # The new output replaces the old whole: the old tree moves aside into the
      # work directory, which is deleted after the new one is in place. If the new
      # one cannot be moved in (another build put one there first), the old one is
      # moved back.
      def publish(output)
        destination = File.join(@root, OUTPUT)
        raise Error, "herd7 output is a symbolic link: #{destination}" if File.symlink?(destination)

        previous = "#{output}.previous"
        File.rename(destination, previous) if File.exist?(destination)
        begin
          File.rename(output, destination)
        rescue SystemCallError => e
          File.rename(previous, destination) if File.exist?(previous) && !File.exist?(destination)
          raise Error, "cannot publish herd7 into #{destination}: #{e.message}"
        end
      end
    end
  end
end
