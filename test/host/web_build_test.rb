# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/web_build'
require_relative '../../tools/lib/erx/web_inventory'

# `make web` (docs/design-web.md, "Build and dependencies"): the tool versions it
# refuses, the names and inventory it writes, and, from the store `tools/erx
# fetch` filled, a build that repeats byte for byte, an install that refuses a
# package the lockfile lacks, and one that runs no package's install script.
class WebBuildTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Build = Erx::WebBuild
  REQUIRED = { 'node' => [24, 2, 0], 'pnpm' => [12, 18, 0] }.freeze

  def test_engines_are_minimum_versions
    assert_equal REQUIRED, Build.engines(File.read(File.join(ROOT, 'web/package.json')))
    ['{}', '{"engines":{"node":">=24.2.0"}}', '{"engines":{"node":"^24.2.0","pnpm":">=12.18.0"}}', 'not json'].each do |text|
      assert_raises(Erx::Error, text) { Build.engines(text) }
    end
  end

  def test_an_older_or_unknown_tool_is_refused
    assert_empty Build.refusals(REQUIRED, 'node' => "v24.2.0\n", 'pnpm' => "12.18.0\n")
    assert_empty Build.refusals(REQUIRED, 'node' => "v26.13.0\n", 'pnpm' => "13.0.0\n")
    assert_equal ['node 24.1.9 is older than the 24.2.0 web/package.json requires'],
                 Build.refusals(REQUIRED, 'node' => "v24.1.9\n", 'pnpm' => "12.18.0\n")
    assert_equal ['pnpm printed no version'], Build.refusals(REQUIRED, 'node' => "v24.2.0\n", 'pnpm' => "corepack: no\n")
  end

  def test_every_file_but_the_index_is_named_by_its_hash
    files = Build.bundle('main.js' => 'script', 'main.css' => 'style', 'main.js.LEGAL.txt' => 'a ',
                         'main.css.LEGAL.txt' => 'b')
    hex = ->(bytes) { Digest::SHA256.hexdigest(bytes)[0, 16] }
    assert_equal ["client-#{hex['script']}.js", "client-#{hex['style']}.css", "notices-#{hex['a b']}.txt", 'index.html'],
                 files.keys
    assert_includes files.fetch('index.html'), %(<script type="module" src="/client-#{hex['script']}.js">)
    assert_includes files.fetch('index.html'), %(<link rel="stylesheet" href="/client-#{hex['style']}.css">)
    refute(Build.bundle('main.js' => 's', 'main.css' => 'c').keys.any? { |path| path.start_with?('notices') })
  end

  def test_an_output_the_bundle_does_not_have_is_refused
    assert_raises(Erx::Error) { Build.bundle('main.js' => 's', 'main.css' => 'c', 'chunk-1.js' => 'x') }
    assert_raises(Erx::Error) { Build.bundle('main.js' => 's') }
  end

def test_a_package_without_an_integrity_hash_is_refused
  lockfile = File.read(File.join(ROOT, 'web/pnpm-lock.yaml'))
  assert_empty Build.unverified(lockfile)
  seeded = lockfile.sub(/^  typescript@7\.0\.2:\n    resolution: \{integrity: [^}]*\}/,
                        "  typescript@7.0.2:\n    resolution: {tarball: https://example.invalid/t.tgz}")
  assert_equal ['typescript@7.0.2'], Build.unverified(seeded)
end

def test_the_install_reaches_no_registry
  staged do |stage|
    Dir.mktmpdir('erx-web-empty-store') do |empty_root|
      assert_raises(Erx::CommandError) { Build.install(root: empty_root, runner: runner, stage: stage) }
    end
    Build.install(root: ROOT, runner: runner, stage: stage)
  end
end

  def test_the_front_end_loads_what_publish_writes
    Dir.mktmpdir('erx-web-build') do |directory|
      output = File.join(directory, 'web')
      files = Build.bundle('main.js' => 'script', 'main.css' => 'style')
      Build.publish(files, output: output)
      assert_equal files.keys.sort, Erx::Web::Inventory.load(output).paths.sort
    end
  end

  def test_a_build_repeats_byte_for_byte
    Dir.mktmpdir('erx-web-build') do |directory|
      outputs = %w[first second].map do |name|
        Build.build(root: ROOT, runner: runner, stage: File.join(directory, "stage-#{name}"),
                    output: File.join(directory, name))
      end
      first, second = outputs.map { |output| Dir.children(output).sort.to_h { |path| [path, File.binread(File.join(output, path))] } }
      assert_equal first, second
      assert_includes first.keys, 'inventory.txt'
      Erx::Web::Inventory.load(outputs.first)
    end
  end

  def test_a_package_the_lockfile_lacks_fails_the_install
    staged do |stage|
      Build.install(root: ROOT, runner: runner, stage: stage)
      # A local package, which an install that let the lockfile change would add offline.
      local_package(stage, 'unlocked')
      edit_package(stage) { |package| package['devDependencies']['unlocked'] = 'file:unlocked' }
      assert_raises(Erx::CommandError) { Build.install(root: ROOT, runner: runner, stage: stage) }
      refute File.exist?(File.join(stage, 'node_modules/unlocked'))
    end
  end

  def test_no_install_script_runs
    staged do |stage|
      marker = File.join(stage, 'install-script-ran')
      script = "node -e " + "require('node:fs').writeFileSync(#{marker.to_json}, 'ran')".to_json
      local_package(stage, 'seed', scripts: { preinstall: script, install: script, postinstall: script })
      # The seed is the stage's only dependency, so pnpm re-locks it offline from
      # the manifest alone. Re-locking a registry package that has peers
      # (react-dom, @types/react-dom) wants registry metadata, which neither
      # the store nor an offline host holds, and a lockfile edited by hand fails
      # pnpm's supply-chain check, which wants the same metadata.
      edit_package(stage) do |package|
        package.merge!('dependencies' => {}, 'devDependencies' => { 'seed' => 'file:seed' })
      end
      runner.run(['pnpm', 'install', '--lockfile-only', '--offline', '--ignore-scripts', '--store-dir',
                  File.join(ROOT, Build::STORE), Build::NO_REGISTRY, *Build::PNPM_OPTIONS],
                 name: 'web-seed-lock', deadline: Build::DEADLINE, chdir: stage, env: Build::OFFLINE_ENV)
      # Without --ignore-scripts pnpm refuses the seed, whose scripts no setting
      # allows, so the install fails; with it the install succeeds and runs none.
      # The marker guards a policy that would run them.
      Build.install(root: ROOT, runner: runner, stage: stage)
      assert File.directory?(File.join(stage, 'node_modules/seed')), 'the seeded package was not installed'
      refute File.exist?(marker), 'an install script ran'
    end
  end

  private

  def runner = @runner ||= Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  def staged
    Dir.mktmpdir('erx-web-build') do |directory|
      stage = File.join(directory, 'stage')
      Build.stage_sources(root: ROOT, stage: stage)
      yield stage
    end
  end

  def local_package(stage, name, scripts: {})
    Dir.mkdir(File.join(stage, name))
    File.write(File.join(stage, name, 'package.json'), JSON.generate(name: name, version: '1.0.0', scripts: scripts))
  end

  def edit_package(stage)
    path = File.join(stage, 'package.json')
    package = JSON.parse(File.read(path))
    yield package
    File.write(path, JSON.generate(package))
  end
end
