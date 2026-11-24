# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/image_apps'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/package_key'
require_relative '../../tools/lib/erx/pack_provenance'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/sdk'
require_relative '../fixtures/manifest_context'

# A package added to an image (docs/design-packaging.md, "Adding an app to an image",
# Erx::ImageApps): examples/dashboard packed with an SDK exported from the tree and a
# development package key of the test's own, described by the machine's file check on the
# host, and planned into the system partition's apps/dashboard.app and its package row, which
# the manifest check binds to the package's artifact, beside the development key the
# build context carries.
class ImageAppsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DASHBOARD = File.join(ROOT, 'examples/dashboard')

  # The domain library's planner as this test needs it: every domain, introduction and
  # session planned, since what is checked here is property 19, not property 12.
  PLANS_EVERYTHING = lambda do |view|
    { 'domains' => view.fetch('order').map { 0 }, 'introductions' => view.fetch('introductions').map { 0 },
      'sessions' => view.fetch('sessions').map { 0 } }
  end

  def self.runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  def self.scratch(prefix)
    Dir.mktmpdir(prefix).tap { |work| Minitest.after_run { FileUtils.rm_rf(work) } }
  end

  def self.sdk
    @sdk ||= begin
      directory = File.join(scratch('erx-image-apps-sdk-'), 'sdk')
      Erx::Sdk.new(root: ROOT, runner: runner, erlc: ENV.fetch('ERX_ERLC'), compiler: ENV.fetch('ERX_CLANG'),
                    linker: ENV.fetch('ERX_LLD')).export(directory)
      Erx::AppPack::Sdk.new(root: directory, erlc: ENV.fetch('ERX_ERLC'))
    end
  end

  def self.signer
    @signer ||= Erx::PackageKey.ensure(directory: Erx::PackageKey.directory(home: scratch('erx-image-apps-home-')))
  end

  # The dashboard packed once from a fresh copy in a directory of its own, and described.
  def self.dashboard = @dashboard ||= pack_dashboard

  def self.pack_dashboard
    work = scratch('erx-image-apps-')
    directory = File.join(work, 'dashboard')
    FileUtils.cp_r(DASHBOARD, directory)
    path = Erx::AppPack.pack(directory: directory, sdk: sdk, signer: signer, output_directory: work, runner: runner, root: ROOT)
    Erx::ImageApps.read(path, sdk: sdk, runner: runner)
  end

  def package(name, memory: 4096)
    Erx::ImageApps::Package.new(path: "/p/#{name}.app", name: name, memory: memory, sha256: "\xab".b * 32, license: 'MIT')
  end

  def test_the_dashboard_enters_an_image_as_its_file_and_rows
    dashboard = self.class.dashboard
    bytes = File.binread(dashboard.path)
    header = Erx::AppPackage.codec.decode_layout('erx_pkg_header', bytes, prefix: true)
    assert_equal ['dashboard', Erx::AppPackage.codec.constant('app_memory_default'),
                  Digest::SHA256.digest(bytes.byteslice(0, header.fetch('header_length')))],
                 [dashboard.name, dashboard.memory, dashboard.sha256]
    assert_equal 'BSD-2-Clause', dashboard.license

    key = self.class.signer.public_key
    plan = Erx::ImageApps.plan([dashboard], enable: %w[dashboard])
    assert_equal({ 'apps/dashboard.app' => dashboard.path }, plan.entries)
    assert_equal "package dashboard\n  input @artifact.package-dashboard\n  enable YES\n", plan.rows

    # The archive's artifacts name the package by its header, beside the release's boot
    # scripts, under the archive's one duplicate-name refusal; the package lies in the
    # system partition, so the archive holds no entry of it.
    paths = %w[domains/erxos/bin/session.boot system/root].map(&:b)
    artifacts = Erx::ProductionImage.artifacts(paths, images: {}, boots: [Erx::ProductionImage.domain_boot('session')], apps: plan)
    assert_equal({ 'kind' => 'package', 'name' => 'dashboard', 'memory' => dashboard.memory,
                   'sha256' => dashboard.sha256.unpack1('H*'), 'gatt' => [] }, artifacts.fetch('package-dashboard'))
    assert_equal 0, artifacts.fetch('session').fetch('entry')

    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    arguments = ManifestContextFixture.arguments(codec)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: platform,
                                                           artifacts: arguments.fetch(:artifacts)
                                                                               .merge(artifacts.slice('package-dashboard')),
                                                           development_key: key))
    # The development manifest, whose apps row takes the package, with the plan's rows.
    board = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    admitted = Erx::Manifest.admit(source: "#{board}#{plan.rows}", codec: codec,
                                   context: context, planner: PLANS_EVERYTHING)
    assert_equal [{ 'name' => 'dashboard', 'sha256' => dashboard.sha256.unpack1('H*'), 'enabled' => true }],
                 admitted.report.fetch('packages')
    assert_equal [[], true], admitted.report.values_at('signers', 'development_key')
  end

  # The package's partition entry carries a package receipt, which the image's provenance
  # resolves to the package attributed whole under the license its header declares,
  # registered as permanent; a package of another license is refused there.
  def test_the_dashboard_enters_under_its_declared_license
    dashboard = self.class.dashboard
    work = self.class.scratch('erx-image-apps-receipts-')
    plan = Erx::ImageApps.plan([dashboard], enable: [])
    entry, = Erx::ProductionImage.package_entries(plan, directory: work, root: ROOT)
    file = File.realpath(dashboard.path)
    assert_equal({ 'path' => 'apps/dashboard.app', 'artifact' => file,
                   'receipt' => File.join(work, 'dashboard.app.receipt.json') }, entry)
    assert_equal({ 'version' => 1, 'kind' => 'package', 'artifact' => { 'path' => file, 'sha256' => Digest::SHA256.file(file).hexdigest } },
                 JSON.parse(File.read(entry.fetch('receipt'))))

    resolve = lambda do |package|
      external = Erx::ProductionImage.package_external(package, root: ROOT, status: plan.status(package))
      catalog = Erx::BuildInputs.pack(root: ROOT, paths: [file, entry.fetch('receipt')])
      Erx::PackProvenance.new(root: ROOT, catalog: catalog, external: [external])
                         .resolve(receipt: entry.fetch('receipt'), artifact: file, build_kind: 'development')
    end
    assert_equal [['apps/dashboard.app', 'BSD-2-Clause', 'permanent']],
                 resolve.call(dashboard).map { |record| record.values_at('path', 'license', 'status') }
    assert_match(/cannot enter the image: .*no permitted grant/,
                 assert_raises(Erx::Error) { resolve.call(dashboard.with(license: 'GPL-2.0-only')) }.message)
    assert_match(/cannot enter the image: unresolved source license/,
                 assert_raises(Erx::Error) { resolve.call(dashboard.with(license: '')) }.message)
  end

  # A package whose license is not permissive is registered package-local only in a local
  # test image's plan (tools/erx pack --local), which a development build accepts; without
  # --local it is permanent and refused, and a permissive package or one that names no
  # license is permanent either way.
  def test_only_a_local_image_takes_a_package_that_is_not_permissive
    gpl = package('doom').with(license: 'GPL-2.0-only')
    local = Erx::ImageApps.plan([gpl], enable: [], local: true)
    assert_equal 'package-local', local.status(gpl)
    assert_equal 'permanent', Erx::ImageApps.plan([gpl], enable: []).status(gpl)
    assert_equal 'permanent', local.status(package('clock'))
    assert_equal 'permanent', local.status(gpl.with(license: ''))
    assert_equal 'package-local', local.status(gpl.with(license: 'MIT AND GPL-2.0-only'))
    assert_equal 'permanent', local.status(gpl.with(license: 'GPL-2.0-only OR MIT'))
    refute Erx::ImageApps.none.local

    dashboard = self.class.dashboard
    restricted = dashboard.with(license: 'GPL-2.0-only')
    resolve = lambda do |plan, build_kind|
      entry, = Erx::ProductionImage.package_entries(plan, directory: self.class.scratch('erx-image-apps-local-'), root: ROOT)
      external = Erx::ProductionImage.package_external(restricted, root: ROOT, status: plan.status(restricted))
      catalog = Erx::BuildInputs.pack(root: ROOT, paths: [entry.fetch('artifact'), entry.fetch('receipt')])
      Erx::PackProvenance.new(root: ROOT, catalog: catalog, external: [external])
                         .resolve(receipt: entry.fetch('receipt'), artifact: entry.fetch('artifact'), build_kind: build_kind)
    end
    local = Erx::ImageApps.plan([restricted], enable: [], local: true)
    assert_equal [['apps/dashboard.app', 'GPL-2.0-only', 'package-local']],
                 resolve.call(local, 'development').map { |record| record.values_at('path', 'license', 'status') }
    assert_match(/cannot enter the image: .*no permitted grant; only a local test image/,
                 assert_raises(Erx::Error) { resolve.call(Erx::ImageApps.plan([restricted], enable: []), 'development') }.message)
    assert_match(/cannot enter the image: .*no permitted grant/, assert_raises(Erx::Error) { resolve.call(local, 'release') }.message)
  end

  # The same packages give the same plan, whatever order they come in:
  # what the image takes for them follows from its inputs alone.
  def test_the_plan_follows_from_its_inputs_alone
    one = Erx::ImageApps.plan([package('quotes'), package('clock')], enable: %w[clock])
    assert_equal one, Erx::ImageApps.plan([package('clock'), package('quotes')], enable: %w[clock])
    assert_equal %w[apps/clock.app apps/quotes.app], one.entries.keys
    assert_match(/\Apackage clock\n.*  enable YES\npackage quotes\n.*  enable NO\n\z/m, one.rows)
  end

  def test_a_plan_refuses_two_packages_of_a_name_and_an_enable_of_none
    error = assert_raises(Erx::Error) { Erx::ImageApps.plan([package('clock'), package('clock')], enable: []) }
    assert_match(/two packages of the image are named clock/, error.message)
    error = assert_raises(Erx::Error) { Erx::ImageApps.plan([package('clock')], enable: %w[doom]) }
    assert_match(/--enable names doom, which no added package is/, error.message)
    deployer = Erx::ImageApps::Signer.new(name: 'deployer', key: "\x02".b * 32)
    error = assert_raises(Erx::Error) do
      Erx::ImageApps.plan([], enable: [], signers: [deployer, deployer])
    end
    assert_match(/two signers of the image are named deployer/, error.message)
    assert_raises(Erx::Error) { Erx::ImageApps::Signer.new(name: "x\nfacet y", key: "\x02".b * 32) }
  end

  # A deployer's key file names its signer row; the builder's own name is refused.
  def test_a_signer_is_named_by_its_key_file
    work = self.class.scratch('erx-image-apps-signer-')
    key = OpenSSL::PKey.generate_key('ED25519')
    File.write(File.join(work, 'deployer.pem'), key.public_to_pem)
    File.write(File.join(work, 'development.pem'), key.public_to_pem)
    File.write(File.join(work, 'secret.pem'), key.private_to_pem)
    signer = Erx::ImageApps.signer(File.join(work, 'deployer.pem'))
    assert_equal ['deployer', key.raw_public_key], [signer.name, signer.key]
    assert_match(/names the builder's own key/,
                 assert_raises(Erx::Error) { Erx::ImageApps.signer(File.join(work, 'development.pem')) }.message)
    assert_match(/is not a PEM public key/,
                 assert_raises(Erx::Error) { Erx::ImageApps.signer(File.join(work, 'secret.pem')) }.message)
    assert_match(/signer deployer\n  key hex:#{key.raw_public_key.unpack1('H*')}\n\z/,
                 Erx::ImageApps.plan([], enable: [], signers: [signer]).rows)
  end

  # The published package key, whose private half the tree holds, is trusted by nothing,
  # so no image takes it as a signer, whatever its file is named.
  def test_the_published_package_key_is_no_signer
    work = self.class.scratch('erx-image-apps-published-')
    published = OpenSSL::PKey.new_raw_public_key('ED25519', Erx::PackageKey.published.public_key)
    File.write(File.join(work, 'deployer.pem'), published.public_to_pem)
    assert_equal "--signer #{work}/deployer.pem is the published package key, which nothing trusts",
                 assert_raises(Erx::Error) { Erx::ImageApps.signer(File.join(work, 'deployer.pem')) }.message
  end

  # The file check refuses a file that is not a package, or one renamed from its app's
  # name, before the image takes it.
  def test_the_file_check_refuses_a_file_that_is_not_its_package
    work = self.class.scratch('erx-image-apps-refused-')
    junk = File.join(work, 'junk.app')
    File.binwrite(junk, "\0" * 8192)
    assert_match(/the file check refuses junk\.app: \{error,\{header,/,
                 assert_raises(Erx::Error) { Erx::ImageApps.read(junk, sdk: self.class.sdk, runner: self.class.runner) }.message)
    renamed = File.join(work, 'clock.app')
    FileUtils.cp(self.class.dashboard.path, renamed)
    assert_match(/the file check refuses clock\.app: \{error,\{name,/,
                 assert_raises(Erx::Error) { Erx::ImageApps.read(renamed, sdk: self.class.sdk, runner: self.class.runner) }.message)
  end
end
