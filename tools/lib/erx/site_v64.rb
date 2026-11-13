# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'error'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # Builds v64, the AArch64 machine in WebAssembly that the website boots
  # erXos on, and collects the license notices of everything compiled into
  # the two files the site ships from it.
  #
  # v64 is used unmodified. deps.lock pins its commit and Closure Compiler,
  # which its JavaScript build needs; `tools/erx fetch` verifies both
  # against their SHA-256 and extracts them under build/third_party. The
  # build copies the verified tree to a fresh STAGING directory and runs
  # `npm ci` and v64's own Makefile there, so the fetched tree stays as
  # fetched.
  module SiteV64
    STAGING = 'build/site-v64'
    # The files the site ships, as v64's Makefile writes them.
    TARGETS = { 'libv86.mjs' => 'build/libv86.mjs', 'v86-arm64.wasm' => 'build/v86-arm64.wasm' }.freeze
    # The notices shipped beside them: v64's own license texts, and the two
    # files this build writes into the staged tree.
    NOTICE_FILE = 'build/NOTICES'
    RUST_NOTICE_FILE = 'build/COPYRIGHT-rust-library.html'
    # Published with .txt names, so a static host serves them as text.
    NOTICES = { 'LICENSE.txt' => 'LICENSE', 'LICENSE.MIT.txt' => 'LICENSE.MIT', 'NOTICES.txt' => NOTICE_FILE,
                'COPYRIGHT-rust-library.html' => RUST_NOTICE_FILE }.freeze

    NPM_DEADLINE = 900
    # Inside the workflow's 45-minute job, so the deadline can name make.
    MAKE_DEADLINE = 1800

    # The sources the two targets compile, as v64's Makefile names them:
    # the bundle's CORE_FILES, BROWSER_FILES and LIB_FILES, and the core's
    # src/rust crate with SoftFloat and zstd linked in. A superset is
    # harmless: it only widens the license check below.
    COMPILED = %w[src/*.js src/{parallel,arm,virt,image,android,tpm,browser}/*.js
                  lib/**/*.{js,c,h} src/rust/**/*.rs].freeze
    # A copyright line or a license grant in a source file.
    LICENSE_STATEMENT = /copyright\s+(?:\(c\)\s*)?\d{4}|licen[cs]ed\s+under|SPDX-License-Identifier/i
    # Compiled sources that state v64's own license (its LICENSE and
    # LICENSE.MIT, shipped as they are).
    V64_OWN = %w[src/floppy.js].freeze
    # Compiled third-party sources. NOTICES carries every copyright block of
    # each, and the license texts, from erXos's tree, that its blocks refer
    # to without including. SoftFloat's blocks hold its whole BSD-3-Clause
    # license; zstd's point at zstd's LICENSE, which erXos's OTP carries.
    THIRD_PARTY = {
      'lib/softfloat/softfloat.c' => [],
      'lib/zstd/zstddeclib.c' => ['otp/erts/emulator/zstd/LICENSE']
    }.freeze

    module_function

    # Needs Node with npm, clang with the wasm32 target, Rust with the
    # wasm32-unknown-unknown target, and Java. `npm ci` installs v64's build
    # tools from its package-lock.json, from the npm registry, without
    # running their install scripts; make skips Closure Compiler's download
    # because CLOSURE names the pinned jar. Returns the staged tree.
    def build(root:, runner:)
      sources = DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
      tree = fetched(root:, sources:, id: 'v64')
      closure = fetched(root:, sources:, id: 'closure-compiler')
      staging = OutputDirectory.check(root:, path: File.join(root, STAGING))
      FileUtils.rm_rf(staging)
      OutputDirectory.prepare(root:, path: staging)
      FileUtils.cp_r(File.join(tree, '.'), staging)

      runner.run(%w[npm ci --ignore-scripts --no-audit --no-fund], name: 'site-v64-npm', deadline: NPM_DEADLINE,
                                                                     chdir: staging)
      # The GLES plugin's rule reruns `npm ci` when esbuild looks older
      # than package.json; the environment keeps install scripts off there too.
      runner.run(['make', '-C', staging, "CLOSURE=#{closure}", *TARGETS.values], name: 'site-v64-make',
                 deadline: MAKE_DEADLINE, env: { 'npm_config_ignore_scripts' => 'true' })
      File.write(File.join(staging, NOTICE_FILE), notices(tree: staging, root:))
      FileUtils.cp(rust_library_notice(runner:, chdir: staging), File.join(staging, RUST_NOTICE_FILE))
      staging
    end

    # The path of a source `tools/erx fetch` verified and extracted: its
    # download record must equal its deps.lock entry.
    def fetched(root:, sources:, id:)
      source = sources.find { |entry| entry.fetch('id') == id }
      raise Error, "deps.lock has no #{id}" unless source

      parent = File.join(root, 'build/third_party', id)
      marker = File.join(parent, '.source.json')
      unless File.file?(marker) && !File.symlink?(marker) &&
             JsonInput.parse(BoundedFile.read(marker, maximum: 65_536), max_bytes: 65_536,
                                                                        label: 'source download record') == source
        raise Error, "#{id} is not fetched as deps.lock pins it: run tools/erx fetch --source #{id}"
      end

      File.join(parent, source.fetch('kind') == 'file' ? source.fetch('filename') : source.fetch('directory'))
    end

    # NOTICES: every copyright block of each third-party source compiled
    # into the shipped files, and the license texts they refer to. Raises
    # Erx::Error naming a compiled source whose license statement has no
    # entry above, so a new input fails the build until its notice is added.
    def notices(tree:, root:)
      unlisted = compiled_sources(tree).reject { |path| V64_OWN.include?(path) || THIRD_PARTY.key?(path) }
                                       .select { |path| LICENSE_STATEMENT.match?(File.binread(File.join(tree, path))) }
      raise Error, "#{unlisted.first} states a license of its own; add its notice to Erx::SiteV64" unless unlisted.empty?

      sections = THIRD_PARTY.flat_map do |path, licenses|
        blocks = copyright_blocks(File.binread(File.join(tree, path)))
        raise Error, "no copyright block found in #{path}" if blocks.empty?

        ["== Copyright notices in v64's #{path}\n\n#{blocks.join("\n\n")}\n",
         *licenses.map { |license| "== The license those notices name, from erXos's #{license}\n\n#{File.read(File.join(root, license))}" }]
      end
      "Third-party code compiled into the website's v64 files, beside v64's own code\n" \
        "(LICENSE and LICENSE.MIT). The Rust standard library's notices are in\n" \
        "COPYRIGHT-rust-library.html.\n\n#{sections.join("\n")}"
    end

    def compiled_sources(tree)
      listed = [*V64_OWN, *THIRD_PARTY.keys].reject { |path| File.file?(File.join(tree, path)) }
      raise Error, "v64 source listed in Erx::SiteV64 is missing: #{listed.first}" unless listed.empty?

      COMPILED.flat_map { |pattern| Dir.glob(pattern, base: tree) }.uniq.sort
              .select { |path| File.file?(File.join(tree, path)) }
    end

    # The distinct C comment blocks of a file that carry a copyright line,
    # in their first order.
    def copyright_blocks(text)
      text.scrub.scan(%r{/\*.*?\*/}m).select { |block| block.match?(/copyright/i) }.uniq
    end

    # The Rust project's notices for the standard library, which the core
    # links: COPYRIGHT-library.html of the toolchain that built it.
    def rust_library_notice(runner:, chdir:)
      record = runner.run(%w[rustc --print sysroot], name: 'site-rust-sysroot', deadline: 60, chdir:)
      sysroot = BoundedFile.read(record.fetch('log'), maximum: 4096).lines.last.to_s.strip
      notice = File.join(sysroot, 'share/doc/rust/COPYRIGHT-library.html')
      raise Error, "the Rust toolchain has no #{notice}" unless File.file?(notice)

      notice
    end
    private_class_method :compiled_sources, :copyright_blocks, :rust_library_notice
  end
end
