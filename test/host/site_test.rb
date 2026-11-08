# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'zlib'
require_relative '../../tools/lib/erx/site'

class SiteTest < Minitest::Test
  REPO = File.expand_path('../..', __dir__)
  COMMIT = '0123456789abcdef0123456789abcdef01234567'
  INDEX = '<script src="{{terminal_js}}"></script><a href="{{source_url}}">{{source_label}}</a>'

  # A fake tree: site/ sources, a built v64 tree with its notices, and an
  # image.
  def with_inputs
    Dir.mktmpdir('erx-site-') do |root|
      files = Erx::Site::PAGE_FILES.to_h { |name| ["site/#{name}", name] }
              .merge('site/index.html' => INDEX)
              .merge(Erx::SiteV64::TARGETS.values.to_h { |path| ["v64/#{path}", path] })
              .merge(Erx::SiteV64::NOTICES.values.to_h { |path| ["v64/#{path}", path] })
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), content)
      end
      image = File.join(root, 'image.boot')
      File.binwrite(image, "erXos image\0" * 1000)
      yield root, image
    end
  end

  def inventory(root, image, ref: COMMIT)
    Erx::Site.inventory(root:, v64: File.join(root, 'v64'), image:, source: Erx::Site.source(ref))
  end

  def test_publish_writes_digest_named_files_notices_and_a_checked_image
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      manifest = Erx::Site.publish(inventory(root, image), out:)

      module_name = manifest.dig(:emulator, :module)
      assert_match %r{\Av64/libv86-[0-9a-f]{16}\.mjs\z}, module_name
      assert_equal 'build/libv86.mjs', File.read(File.join(out, module_name))
      assert_match %r{\Av64/v86-arm64-[0-9a-f]{16}\.wasm\z}, manifest.dig(:emulator, :wasm)
      assert_equal 'build/NOTICES', File.read(File.join(out, 'v64/NOTICES.txt'))
      assert_equal 'LICENSE.MIT', File.read(File.join(out, 'v64/LICENSE.MIT.txt'))
      assert File.file?(File.join(out, 'v64/COPYRIGHT-rust-library.html'))
      assert_equal 'favicon.svg', File.read(File.join(out, 'favicon.svg'))
      refute File.exist?(File.join(out, 'terminal.js')), 'only the digest-named terminal.js is published'
      assert_equal File.binread(image), Zlib.gunzip(File.binread(File.join(out, manifest.fetch(:image))))
      written = JSON.parse(File.read(File.join(out, 'boot.json')), symbolize_names: true)
      assert_equal manifest, written
      assert_equal Digest::SHA256.file(image).hexdigest, written.fetch(:sha256)
      assert_equal File.size(File.join(out, written.fetch(:image))), written.fetch(:compressed_bytes)
      assert_equal manifest, Erx::Site.publish(inventory(root, image), out:), 'a rebuild gives the same bytes'
    end
  end

  def test_index_names_the_digest_named_script_and_links_the_image_source
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      manifest = Erx::Site.publish(inventory(root, image), out:)
      terminal = Dir.glob('terminal-*.js', base: out).first

      assert_match(/\Aterminal-[0-9a-f]{16}\.js\z/, terminal)
      assert_equal "<script src=\"#{terminal}\"></script>" \
                   "<a href=\"https://github.com/stass/erXos/tree/#{COMMIT}\">#{COMMIT[0, 12]}</a>",
                   File.read(File.join(out, 'index.html'))
      assert_equal({ ref: COMMIT, url: "https://github.com/stass/erXos/tree/#{COMMIT}" }, manifest.fetch(:source))
    end
  end

  def test_a_changed_input_changes_its_published_name
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      first = Erx::Site.publish(inventory(root, image), out:)
      File.write(File.join(root, 'v64/build/v86-arm64.wasm'), 'another core')
      second = Erx::Site.publish(inventory(root, image), out:)

      refute_equal first.dig(:emulator, :wasm), second.dig(:emulator, :wasm)
      assert_equal first.dig(:emulator, :module), second.dig(:emulator, :module)
      refute File.exist?(File.join(out, first.dig(:emulator, :wasm)))
    end
  end

  def test_a_rebuild_with_another_image_replaces_the_old_one
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      first = Erx::Site.publish(inventory(root, image), out:)
      File.binwrite(image, 'another image')
      second = Erx::Site.publish(inventory(root, image), out:)

      refute_equal first.fetch(:image), second.fetch(:image)
      refute File.exist?(File.join(out, first.fetch(:image)))
      assert_equal 'another image', Zlib.gunzip(File.binread(File.join(out, second.fetch(:image))))
      assert_equal [], Dir.children(File.join(root, 'build')) - ['site'], 'no staging directory is left behind'
    end
  end

  def test_a_missing_input_is_named
    with_inputs do |root, image|
      File.delete(File.join(root, 'v64/build/NOTICES'))
      error = assert_raises(Erx::Error) { inventory(root, image) }
      assert_match %r{v64/build/NOTICES}, error.message
    end
  end

  def test_publish_refuses_to_replace_a_directory_it_did_not_build
    with_inputs do |root, image|
      assert_raises(Erx::Error) { Erx::Site.publish(inventory(root, image), out: File.join(root, 'site')) }
      assert File.file?(File.join(root, 'site/index.html'))
    end
  end

  def test_routes_serve_the_built_site_but_not_its_marker
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      Erx::Site.publish(inventory(root, image), out:)
      assert File.file?(File.join(out, Erx::Site::MARKER)), 'the marker is written'

      table = Erx::Site.routes(out)
      assert_equal File.join(out, 'index.html'), table.fetch('/')
      assert table.key?('/boot.json')
      assert_nil table['/../image.boot']
      assert_nil table["/#{Erx::Site::MARKER}"]
    end
  end

  def test_the_image_source_is_a_tag_or_a_full_commit
    assert_equal 'v0.1.0', Erx::Site.source('v0.1.0').label
    assert_equal COMMIT[0, 12], Erx::Site.source(COMMIT).label
    ['', 'v0.1/../x', '../x', 'a b', 'v1"><script>', '-v1', 'main~1', "v1\n", 'x' * 101, nil].each do |ref|
      assert_raises(Erx::Error, ref.inspect) { Erx::Site.source(ref) }
    end
  end

  def test_an_unknown_index_placeholder_is_refused
    error = assert_raises(Erx::Error) do
      Erx::Site.render_index('{{nope}}', terminal: 't.js', source: Erx::Site.source(COMMIT))
    end
    assert_match(/nope/, error.message)
  end

  # A staged v64 tree with the two third-party sources and v64's own.
  def with_v64_tree
    Dir.mktmpdir('erx-v64-') do |root|
      files = { 'v64/src/cpu.js' => "// the CPU\n",
                'v64/src/floppy.js' => "// licensed under both BSD and MIT, see LICENSE and LICENSE.MIT\n",
                'v64/lib/softfloat/softfloat.c' => "/* SoftFloat\nCopyright 2011 The Regents */\nint a;\n" \
                                                   "/* SoftFloat\nCopyright 2011 The Regents */\nint b;\n",
                'v64/lib/zstd/zstddeclib.c' => "/*\n * Copyright (c) 2016-2020, Facebook, Inc.\n */\n",
                'otp/erts/emulator/zstd/LICENSE' => "BSD License\n\nFor Zstandard software\n" }
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), content)
      end
      yield File.join(root, 'v64'), root
    end
  end

  def test_notices_carry_each_third_party_block_once_and_the_licence_it_names
    with_v64_tree do |tree, root|
      notices = Erx::SiteV64.notices(tree:, root:)
      assert_equal 1, notices.scan('Copyright 2011 The Regents').size
      assert_includes notices, 'Copyright (c) 2016-2020, Facebook, Inc.'
      assert_includes notices, "For Zstandard software\n"
      refute_includes notices, "the CPU"
    end
  end

  def test_a_new_licensed_input_fails_the_build
    with_v64_tree do |tree, root|
      FileUtils.mkdir_p(File.join(tree, 'src/arm'))
      File.write(File.join(tree, 'src/arm/vendored.js'), "// Copyright (c) 2024 Someone. MIT.\n")
      error = assert_raises(Erx::Error) { Erx::SiteV64.notices(tree:, root:) }
      assert_match %r{src/arm/vendored\.js}, error.message
    end
  end

  def test_a_listed_source_that_disappears_fails_the_build
    with_v64_tree do |tree, root|
      File.delete(File.join(tree, 'lib/zstd/zstddeclib.c'))
      error = assert_raises(Erx::Error) { Erx::SiteV64.notices(tree:, root:) }
      assert_match %r{lib/zstd/zstddeclib\.c}, error.message
    end
  end

  def test_the_fetched_v64_compiles_no_unlisted_licence
    tree = File.join(REPO, 'build/third_party/v64/v64-87d26de')
    skip 'v64 is not fetched' unless File.directory?(tree)

    assert_match(/Berkeley|SoftFloat/, Erx::SiteV64.notices(tree:, root: REPO))
  end

  def test_the_build_uses_the_fetched_tree_as_deps_lock_pins_it
    Dir.mktmpdir('erx-v64-') do |root|
      sources = Erx::DependencySchema.parse(File.binread(File.join(REPO, 'deps.lock')))
      v64 = sources.find { |source| source.fetch('id') == 'v64' }
      parent = File.join(root, 'build/third_party/v64')
      FileUtils.mkdir_p(File.join(parent, v64.fetch('directory')))
      assert_raises(Erx::Error) { Erx::SiteV64.fetched(root:, sources:, id: 'v64') }

      File.write(File.join(parent, '.source.json'), JSON.generate(v64))
      assert_equal File.join(parent, v64.fetch('directory')), Erx::SiteV64.fetched(root:, sources:, id: 'v64')
      File.write(File.join(parent, '.source.json'), JSON.generate(v64.merge('commit' => '0' * 40)))
      assert_raises(Erx::Error) { Erx::SiteV64.fetched(root:, sources:, id: 'v64') }
    end
  end

  # The workflow's checks of its inputs, run as the workflow runs them.
  def test_the_workflow_validates_its_inputs
    workflow = YAML.safe_load(File.read(File.join(REPO, '.github/workflows/site.yml')))
    assert_equal({ 'group' => 'pages', 'cancel-in-progress' => false }, workflow.fetch('concurrency'))
    steps = workflow.dig('jobs', 'build', 'steps')
    check = steps.find { |step| step['name'] == 'Check the inputs' }.fetch('run')
    good = { 'IMAGE_SHA256' => 'a' * 64, 'IMAGE_SOURCE' => COMMIT }
    assert system(good, 'bash', '-e', '-c', check, out: File::NULL, err: File::NULL)
    [{ 'IMAGE_SHA256' => 'A' * 64 }, { 'IMAGE_SHA256' => "#{'a' * 64}\nb" }, { 'IMAGE_SHA256' => 'a' * 63 },
     { 'IMAGE_SOURCE' => '../x' }, { 'IMAGE_SOURCE' => 'v1 x' }, { 'IMAGE_SOURCE' => '' }].each do |bad|
      refute system(good.merge(bad), 'bash', '-e', '-c', check, out: File::NULL, err: File::NULL), bad.inspect
    end
    download = steps.find { |step| step['name'] == 'Download the erXos image' }.fetch('run')
    assert_includes download, 'sha256sum --check --strict'
  end
end
