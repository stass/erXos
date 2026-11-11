# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'error'
require_relative 'generated'
require_relative 'json_input'
require_relative 'web_stage'

module Erx
  # The web client's build (docs/design-web.md, "Build and dependencies").
  #
  # fetch is the one step that reaches the network: `pnpm fetch` fills a store
  # under the build tree with the packages web/pnpm-lock.yaml pins, each checked
  # against the lockfile's integrity hash, and records the lockfile's SHA-256
  # beside the store. build is `make web`, offline from that store: it refuses a
  # Node.js or pnpm older than web/package.json's engines and a store fetched for
  # another lockfile, stages web/ with the generated modules of build/gen/web
  # over it, installs with `--offline --frozen-lockfile --ignore-scripts`, so no
  # package outside the lockfile and no install script runs, type-checks with
  # `tsc --noEmit`, bundles src/main.ts with esbuild, and writes build/web/.
  #
  # build/web/ holds index.html, which names the script and the stylesheet;
  # every other file is named by its stem and the first 16 hexadecimal digits of
  # its own SHA-256, so a front end may serve it as immutable; and inventory.txt
  # lists each file with its SHA-256 (Web::Inventory reads it). The pure part
  # (engines, bundle, inventory) decides the names and bytes; the effects around
  # it only run the tools and move files.
  module WebBuild
    STORE = 'build/web-store'
    STAGE = 'build/web-stage'
    OUTPUT = 'build/web'
    # The record of the lockfile the store was fetched for, inside the store.
    FETCHED = 'fetched-lock.sha256'
    LOCKFILE = 'pnpm-lock.yaml'
    # What pnpm reads to fetch: the lockfile, the package it locks and the
    # settings that say no package may run a build script.
    PACKAGE_FILES = ['package.json', LOCKFILE, 'pnpm-workspace.yaml'].freeze
    # pnpm's own network use beyond the registry: its check for a newer pnpm.
    PNPM_OPTIONS = ['--config.update-notifier=false'].freeze
    # A registry no request reaches, for every step after fetch: a step that
    # wanted the network fails instead of fetching.
    NO_REGISTRY = '--config.registry=http://127.0.0.1:9/'
    # pnpm run through corepack (as on a host with no npm) may not download a
    # pnpm of its own after fetch either.
    # pnpm run through corepack does not reach for a newer pnpm in any step.
    PNPM_ENV = { 'COREPACK_DEFAULT_TO_LATEST' => '0' }.freeze
    # Nor may the caller's environment swap esbuild's binary or load code into Node.
    OFFLINE_ENV = PNPM_ENV.merge('COREPACK_ENABLE_NETWORK' => '0', 'ESBUILD_BINARY_PATH' => nil, 'NODE_OPTIONS' => nil).freeze
    ESBUILD_OPTIONS = %w[--bundle --format=esm --platform=browser --target=es2022 --minify --charset=ascii
                         --legal-comments=external --entry-names=main --log-level=warning].freeze
    # esbuild's outputs for src/main.ts, by its name, and the name stem each
    # takes in build/web/; the legal comments of both outputs make one notices file.
    SCRIPT = 'main.js'
    STYLESHEET = 'main.css'
    LEGAL = %w[main.js.LEGAL.txt main.css.LEGAL.txt].freeze
    HASH_DIGITS = 16
    DEADLINE = 600
    VERSION = /\Av?(\d+)\.(\d+)\.(\d+)\s*\z/
    MINIMUM = /\A>=\s*(\d+)\.(\d+)\.(\d+)\z/

    module_function

    # The minimum version of each tool package.json's engines names, as
    # { 'node' => [24, 2, 0], 'pnpm' => [12, 18, 0] }. engines states each as
    # ">=X.Y.Z" and nothing else, so every host reads the same requirement.
    def engines(package_json)
      package = JsonInput.parse(package_json, max_bytes: 64 * 1024, label: 'web/package.json')
      engines = package.is_a?(Hash) ? package['engines'] : nil
      raise Error, 'web/package.json names no engines for node and pnpm' unless
        engines.is_a?(Hash) && engines.keys.sort == %w[node pnpm]

      engines.to_h do |tool, range|
        numbers = range.is_a?(String) && range.match(MINIMUM)&.captures
        raise Error, "web/package.json: engines.#{tool} is not >=X.Y.Z" unless numbers

        [tool, numbers.map(&:to_i)]
      end
    end

    # Each tool of found (tool => what its --version printed) that is older than
    # required, or printed no version, as a sentence; empty when all are new enough.
    def refusals(required, found)
      required.filter_map do |tool, minimum|
        printed = found.fetch(tool)
        version = printed.match(VERSION)&.captures&.map(&:to_i)
        next "#{tool} printed no version" unless version
        next if (version <=> minimum) >= 0

        "#{tool} #{version.join('.')} is older than the #{minimum.join('.')} web/package.json requires"
      end
    end

    # build/web/'s files from esbuild's outputs (name => bytes): the script,
    # the stylesheet and the notices named by their hashes, and index.html
    # naming the first two. An output of another name (a chunk, an asset)
    # is refused, as the front ends serve only these kinds.
    def bundle(outputs)
      unknown = outputs.keys - [SCRIPT, STYLESHEET, *LEGAL]
      raise Error, "esbuild wrote #{unknown.sort.join(', ')}, which the client's bundle does not have" unless unknown.empty?
      raise Error, "esbuild wrote no #{SCRIPT} or no #{STYLESHEET}" unless outputs.key?(SCRIPT) && outputs.key?(STYLESHEET)

      notices = LEGAL.filter_map { |name| outputs[name] }.join
      script = hashed('client', outputs.fetch(SCRIPT), '.js')
      stylesheet = hashed('client', outputs.fetch(STYLESHEET), '.css')
      files = { script => outputs.fetch(SCRIPT), stylesheet => outputs.fetch(STYLESHEET) }
      files[hashed('notices', notices, '.txt')] = notices unless notices.empty?
      files.merge('index.html' => index_html(script: script, stylesheet: stylesheet))
    end

    # stem-HEX.kind, HEX the first HASH_DIGITS hexadecimal digits of bytes' SHA-256.
    def hashed(stem, bytes, kind) = "#{stem}-#{Digest::SHA256.hexdigest(bytes)[0, HASH_DIGITS]}#{kind}"

    # The page every path of the client loads; the paths are absolute, since the
    # client routes every other path to this page (docs/design-web.md, "URLs").
    def index_html(script:, stylesheet:)
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>erXos</title>
        <link rel="stylesheet" href="/#{stylesheet}">
        <script type="module" src="/#{script}"></script>
        </head>
        <body></body>
        </html>
      HTML
    end

# The entries of a pnpm lockfile's packages section that pnpm would fetch
# without checking an integrity hash (a git, tarball or directory source),
# by name. fetch and build refuse a lockfile with any, so every package
# is verified against the hash the lockfile pins.
def unverified(lockfile)
  section = lockfile.split(/^packages:\n/, 2).fetch(1, '').split(/^\S/, 2).first
  section.split(/^(?=  \S)/).reject { |entry| entry.strip.empty? }.filter_map do |entry|
    name = entry.lines.first.strip.delete_suffix(':')
    name unless entry.match?(/^    resolution: \{integrity: sha512-[A-Za-z0-9+\/]+=*\}$/)
  end
end

def verify_lockfile(root)
  bad = unverified(File.read(File.join(root, 'web', LOCKFILE)))
  raise Error, "web/#{LOCKFILE} pins without an integrity hash: #{bad.join(', ')}" unless bad.empty?
end

    # inventory.txt for files (path => bytes): sha256sum's format, sorted by path.
    def inventory(files)
      files.sort.map { |path, bytes| "#{Digest::SHA256.hexdigest(bytes)}  #{path}\n" }.join
    end

    # The lockfile's SHA-256, which the store records when fetched for it.
    def lock_digest(root) = Digest::SHA256.file(File.join(root, 'web', LOCKFILE)).hexdigest

    def fetched?(root:)
      record = File.join(root, STORE, FETCHED)
      File.file?(record) && File.read(record).strip == lock_digest(root)
    end

    # `tools/erx fetch`: pnpm fetch from a copy of web/'s package files, so
    # nothing is written under web/, into the store; then the record.
    def fetch(root:, runner:)
      verify_lockfile(root)
      check_versions(root: root, runner: runner)
      store = File.join(root, STORE)
      work = fresh(File.join(root, 'build/web-fetch'))
      PACKAGE_FILES.each { |name| FileUtils.cp(File.join(root, 'web', name), work) }
      runner.run(['pnpm', 'fetch', '--store-dir', store, *PNPM_OPTIONS], name: 'web-fetch', deadline: DEADLINE, chdir: work,
                                                                       env: PNPM_ENV)
      FileUtils.rm_rf(work)
      File.write(File.join(store, FETCHED), "#{lock_digest(root)}\n")
      store
    end

    # `make web`: build/web/ from web/ and the store, offline. stage and output
    # are where the staged tree and the client go.
    def build(root:, runner:, stage: File.join(root, STAGE), output: File.join(root, OUTPUT))
      verify_lockfile(root)
      check_versions(root: root, runner: runner)
      raise Error, "the web client's packages are not fetched for web/#{LOCKFILE}; run `tools/erx fetch`" unless
        fetched?(root: root)

      stage_sources(root: root, stage: stage)
      install(root: root, runner: runner, stage: stage)
      in_stage = ->(name, argv) { runner.run(argv, name: name, deadline: DEADLINE, chdir: stage, env: OFFLINE_ENV) }
      in_stage.call('web-tsc', ['node', 'node_modules/typescript/bin/tsc', '--noEmit', '--project', 'tsconfig.json'])
      in_stage.call('web-esbuild', ['node', 'node_modules/esbuild/bin/esbuild', 'src/main.ts', *ESBUILD_OPTIONS,
                                   '--outdir=out'])
      outputs = Dir.children(File.join(stage, 'out')).to_h { |name| [name, File.binread(File.join(stage, 'out', name))] }
      publish(bundle(outputs), output: output)
    end

    # The packages stage/pnpm-lock.yaml pins, from the store into stage/node_modules,
    # with no network, no package the lockfile lacks and no install script.
    def install(root:, runner:, stage:)
      runner.run(['pnpm', 'install', '--offline', '--frozen-lockfile', '--ignore-scripts', '--store-dir',
                  File.join(root, STORE), NO_REGISTRY, *PNPM_OPTIONS],
                 name: 'web-install', deadline: DEADLINE, chdir: stage, env: OFFLINE_ENV)
    end

    # web/ with build/gen/web over it, in a stage made afresh.
    def stage_sources(root:, stage:)
      fresh(stage)
      Generated.ensure(root: root) do |result|
        [File.join(root, 'web'), File.join(result.output, 'web')].each { |tree| WebStage.copy(tree, stage) }
      end
    end

    # files and their inventory into output, written beside it and renamed over
    # it, so a reader never sees a part of one build with a part of another.
    def publish(files, output:)
      next_output = fresh("#{output}.next")
      files.each { |path, bytes| File.binwrite(File.join(next_output, path), bytes) }
      File.binwrite(File.join(next_output, 'inventory.txt'), inventory(files))
      FileUtils.rm_rf(output)
      File.rename(next_output, output)
      output
    end

    def check_versions(root:, runner:)
      required = engines(File.read(File.join(root, 'web/package.json')))
      found = required.keys.to_h { |tool| [tool, version_of(tool, root: root, runner: runner)] }
      refused = refusals(required, found)
      raise Error, "the web client's tools: #{refused.join('; ')}" unless refused.empty?
    end

    # What `tool --version` prints, run from the build tree so no package.json
    # of the tree's is in reach.
    def version_of(tool, root:, runner:)
      logs = File.join(root, 'build/logs')
      FileUtils.mkdir_p(logs)
      out = File.join(logs, "web-#{tool}-version.out")
      runner.run([tool, '--version'], name: "web-#{tool}-version", deadline: 60, chdir: logs, env: OFFLINE_ENV, stdout: out)
      File.read(out, 64).to_s
    end

    def fresh(directory)
      FileUtils.rm_rf(directory)
      FileUtils.mkdir_p(directory)
      directory
    end
  end
end
