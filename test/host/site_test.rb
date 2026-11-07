# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
require_relative '../../tools/lib/erx/site'

class SiteTest < Minitest::Test
  # A fake tree: site/ sources, a v64 checkout with its build outputs, and
  # an image.
  def with_inputs
    Dir.mktmpdir('erx-site-') do |root|
      (Erx::Site::PAGE_FILES.map { |name| "site/#{name}" } +
       Erx::Site::V64_BUILD_FILES.map { |name| "v64/build/#{name}" } +
       Erx::Site::V64_LICENSES.map { |name| "v64/#{name}" }).each do |path|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), path)
      end
      image = File.join(root, 'image.boot')
      File.binwrite(image, "erXos image\0" * 1000)
      yield root, image
    end
  end

  def test_publish_writes_pages_emulator_licenses_and_a_checked_image
    with_inputs do |root, image|
      plan = Erx::Site.plan(root:, v64: File.join(root, 'v64'), image:)
      out = File.join(root, 'build/site')
      manifest = Erx::Site.publish(plan, out:)

      assert_equal 'v64/build/libv86.mjs', File.read(File.join(out, 'v64/libv86.mjs'))
      assert_equal 'v64/LICENSE', File.read(File.join(out, 'v64/LICENSE'))
      assert_equal File.binread(image), Zlib.gunzip(File.binread(File.join(out, manifest.fetch(:image))))
      written = JSON.parse(File.read(File.join(out, 'boot.json')), symbolize_names: true)
      assert_equal manifest, written
      assert_equal Digest::SHA256.file(image).hexdigest, written.fetch(:sha256)
      assert_equal File.size(File.join(out, written.fetch(:image))), written.fetch(:compressed_bytes)
      assert_equal manifest, Erx::Site.publish(plan, out:), 'a rebuild gives the same bytes'
    end
  end

  def test_a_rebuild_with_another_image_replaces_the_old_one
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      first = Erx::Site.publish(Erx::Site.plan(root:, v64: File.join(root, 'v64'), image:), out:)
      File.binwrite(image, 'another image')
      second = Erx::Site.publish(Erx::Site.plan(root:, v64: File.join(root, 'v64'), image:), out:)

      refute_equal first.fetch(:image), second.fetch(:image)
      refute File.exist?(File.join(out, first.fetch(:image)))
      assert_equal 'another image', Zlib.gunzip(File.binread(File.join(out, second.fetch(:image))))
      assert_equal [], Dir.children(File.join(root, 'build')) - ['site'], 'no staging directory is left behind'
    end
  end

  def test_a_missing_input_is_named
    with_inputs do |root, image|
      File.delete(File.join(root, 'v64/build/v86-arm64.wasm'))
      error = assert_raises(Erx::Error) { Erx::Site.plan(root:, v64: File.join(root, 'v64'), image:) }
      assert_match %r{v64/build/v86-arm64\.wasm}, error.message
    end
  end

  def test_publish_refuses_to_replace_a_directory_it_did_not_build
    with_inputs do |root, image|
      plan = Erx::Site.plan(root:, v64: File.join(root, 'v64'), image:)
      assert_raises(Erx::Error) { Erx::Site.publish(plan, out: File.join(root, 'site')) }
      assert File.file?(File.join(root, 'site/index.html'))
    end
  end

  def test_routes_list_only_the_files_of_the_site
    with_inputs do |root, _image|
      table = Erx::Site.routes(File.join(root, 'site'))
      assert_equal File.join(root, 'site/index.html'), table.fetch('/')
      assert_nil table['/../v64/LICENSE']
      assert_nil table['/.erx-site']
    end
  end
end
