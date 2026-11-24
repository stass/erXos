# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/doom_program'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/runner'

# The Doom example in the published media (DoomProgram): the build refuses a fork that is
# not fetched or lacks the gitlink's commit, compiles that commit's own bytes, and the image
# takes /bin/doom with libdoom.a attributed as the example.
class DoomProgramTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  FORK = Erx::DoomProgram::EXAMPLE.path

  def setup
    @root = Dir.mktmpdir('erx-doom-')
    @runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(directory, *arguments, input: '')
    out, status = Open3.capture2e('git', '-C', directory, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
                                  'commit.gpgsign=false', *arguments, stdin_data: input)
    raise out unless status.success?

    out.chomp
  end

  # The pinned commit's files, and the second commit's.
  PINNED_FILES = { 'LICENSE' => 'license', 'doomgeneric/doom.c' => 'committed', 'doomgeneric/doom.h' => 'header' }.freeze
  LATER_FILES = { 'LICENSE' => 'later license', 'doomgeneric/doom.c' => 'later' }.freeze

  # A superproject at @root whose gitlink pins the fork's first commit (PINNED_FILES), the
  # fork checked out beside it at a second commit (LATER_FILES), and the WAD where the
  # fetch puts it. Returns both commits.
  def superproject
    fork = File.join(@root, FORK)
    FileUtils.mkdir_p(File.join(fork, 'doomgeneric'))
    git(fork, 'init', '-q')
    commits = [PINNED_FILES, LATER_FILES].map do |files|
      files.each { |name, text| File.write(File.join(fork, name), text) }
      git(fork, 'add', *files.keys)
      git(fork, 'commit', '-q', '-m', files.fetch('doomgeneric/doom.c'))
      git(fork, 'rev-parse', 'HEAD')
    end
    git(@root, 'init', '-q')
    git(@root, 'update-index', '--add', '--cacheinfo', "160000,#{commits.first},#{FORK}")
    git(@root, 'commit', '-q', '-m', 'pin')
    FileUtils.mkdir_p(File.join(@root, File.dirname(Erx::DoomProgram::WAD)))
    File.write(File.join(@root, Erx::DoomProgram::WAD), 'IWAD')
    commits
  end

  def check = Erx::DoomProgram.check_fetched(root: @root, runner: @runner, wad_sha256: Digest::SHA256.hexdigest('IWAD'))

  # Every file below directory, by its path there, with its bytes.
  def files_below(directory)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: directory).reject { File.directory?(File.join(directory, it)) }
       .to_h { [it, File.binread(File.join(directory, it))] }
  end

  def test_the_build_refuses_an_example_not_fetched
    error = assert_raises(Erx::Error) { check }
    assert_match(/not fetched: run `tools\/erx fetch --example doom`/, error.message)
  end

  # The build compiles the gitlink's commit from the fork's objects, so the checkout may
  # stand anywhere, changed or not, while a fork that does not hold that commit, or a WAD
  # other than Freedoom 0.13.0's, is refused before anything is built.
  def test_the_build_takes_a_fork_that_holds_the_pinned_commit
    superproject
    File.write(File.join(@root, FORK, 'LICENSE'), 'changed')
    check
    error = assert_raises(Erx::Error) { Erx::DoomProgram.check_fetched(root: @root, runner: @runner) }
    assert_match(/freedoom1\.wad has SHA-256 \h{64}, not Freedoom 0\.13\.0's #{Erx::DoomProgram::WAD_SHA256}/, error.message)

    absent = '0123456789abcdef0123456789abcdef01234567'
    git(@root, 'update-index', '--cacheinfo', "160000,#{absent},#{FORK}")
    git(@root, 'commit', '-q', '-m', 'repin')
    error = assert_raises(Erx::Error) { check }
    assert_match(/#{FORK} does not hold the commit #{absent} the tree's gitlink records/, error.message)
  end

  # What the build compiles is the pinned commit's blobs, whatever the checkout holds,
  # though check_fetched passes it: a file marked assume-unchanged and one marked
  # skip-worktree carry edits git status does not see, an ignored file sits among the
  # sources, a filter the checkout's own attributes and configuration name would rewrite
  # every file git writes out, and a replace object stands in for one of the commit's
  # blobs.
  def test_the_build_compiles_the_pinned_commits_bytes
    first, = superproject
    fork = File.join(@root, FORK)
    git(fork, 'checkout', '-q', first)
    git(fork, 'update-index', '--assume-unchanged', 'doomgeneric/doom.c')
    File.write(File.join(fork, 'doomgeneric/doom.c'), 'edited')
    git(fork, 'update-index', '--skip-worktree', 'LICENSE')
    File.write(File.join(fork, 'LICENSE'), 'edited')
    File.write(File.join(fork, '.git/info/exclude'), "stdio.h\n")
    File.write(File.join(fork, 'doomgeneric/stdio.h'), 'shadow')
    File.write(File.join(fork, '.git/info/attributes'), "* filter=rewrite\n")
    File.open(File.join(fork, '.git/config'), 'a') { it.write("[filter \"rewrite\"]\n\tsmudge = sed s/^/rewritten/\n") }
    git(fork, 'replace', git(fork, 'rev-parse', "#{first}:doomgeneric/doom.h"), git(fork, 'hash-object', '-w', 'LICENSE'))
    assert_empty git(fork, 'status', '--porcelain'), 'the fixture checkout reads as clean'
    check

    source = Erx::DoomProgram.snapshot(root: @root, runner: @runner)
    assert_equal Erx::DoomProgram.source_directory(@root), source
    assert_equal PINNED_FILES, files_below(File.dirname(source))
    # A file an earlier snapshot holds does not outlive the next one.
    File.write(File.join(source, 'stale.c'), 'stale')
    Erx::DoomProgram.snapshot(root: @root, runner: @runner)
    assert_equal PINNED_FILES, files_below(File.dirname(source))
  end

  # The snapshot writes only regular files at plain paths: a pinned commit holding a
  # repository directory under any case of `.git`, or a symbolic link, is refused, and
  # nothing of it is written.
  def test_the_snapshot_refuses_what_is_not_a_plain_file
    superproject
    fork = File.join(@root, FORK)
    blob = git(fork, 'hash-object', '-w', '--stdin', input: 'x')
    config = git(fork, 'mktree', input: "100644 blob #{blob}\tconfig\n")
    ["040000 tree #{config}\t.GIT\n", "120000 blob #{blob}\tlink\n"].each do |line|
      commit = git(fork, 'commit-tree', git(fork, 'mktree', input: line), '-m', 'odd')
      git(@root, 'update-index', '--cacheinfo', "160000,#{commit},#{FORK}")
      git(@root, 'commit', '-q', '-m', 'repin')
      error = assert_raises(Erx::Error) { Erx::DoomProgram.snapshot(root: @root, runner: @runner) }
      assert_match(/pinned commit holds .*, which is not a regular file at a plain path/, error.message)
      assert_empty files_below(File.join(@root, Erx::DoomProgram::SNAPSHOT))
    end
  end

  # /bin/doom is a program of the domain release, and its archive is attributed whole as
  # the example, with the GPL-2.0 text and Freedoom's license as its notices.
  def test_the_image_takes_bin_doom_as_the_example
    codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    doom = { program: '/b/doom', receipt: '/b/doom.receipt', inputs: ['/b/doom.o'], archive: '/b/libdoom.a' }
    parts = Erx::ProductionImage.example_parts(doom, codec: codec)
    assert_equal ["#{Erx::ReleaseFiles::DOMAIN_PREFIX}bin/doom"], parts.entries.map { it.fetch('path') }
    assert_equal ['/b/doom.o'], parts.inputs
    assert_equal 1, parts.archives.size
    archive = parts.archives.first
    assert_equal ['/b/libdoom.a', Erx::PackProvenance::EXAMPLE_LABEL, 'example'], [archive.path, archive.label, archive.status]
    assert_includes Erx::PackProvenance::EXAMPLE_LICENSES, archive.license
    assert_equal [File.join(Erx::DoomProgram::SNAPSHOT, 'LICENSE'), File.join(File.dirname(Erx::DoomProgram::WAD), 'COPYING.txt')], archive.notices
  end

  # The website's image (InteractiveBoot, `tools/erx boot --without-web`: the site's machine
  # and manifest, through ProductionImage#build) never carries Doom: what it hands the one
  # build asks for no example, so domain_parts adds no bin/doom entry.
  def test_the_site_image_carries_no_doom
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '',
                                     machine: Erx::ProductionImage::Machine.site(PLATFORM), fiasco: Object.new,
                                     runtime: nil, jit_runtime: nil)
    asked = nil
    image.define_singleton_method(:domain_boots) { |_source, given: []| given }
    image.define_singleton_method(:assemble) { |**arguments| asked = arguments }
    image.build(directory: '/nonexistent', manifest_source: PLATFORM.site_manifest_source(ROOT), record: true)
    refute asked.fetch(:doom, false), 'the site image asks for the Doom example'
    assert_empty(asked.fetch(:added).entries.map { it.fetch('path') }.grep(%r{bin/doom\z}))
  end

  # Doom follows from the published kind alone (ProductionImage::MediumKind): it is the
  # one kind whose medium asks the one build for it, and both `tools/erx pack` and the
  # build refuse a tree whose fork is not fetched before they build anything, here a tree
  # with no fork at all standing in for the builder's.
  def test_only_a_published_medium_carries_doom
    kind = Erx::ProductionImage::MediumKind
    added = Erx::ProductionImage::Added.new(entries: [{ 'path' => 'bin/probe' }].freeze, inputs: [].freeze, imports: {}.freeze)
    asked = [kind.development, kind.test(test_programs: added), kind.published].to_h do |medium|
      image = builder(Erx::ProductionImage::Machine.development(PLATFORM))
      image.define_singleton_method(:domain_boots) { |_source, given: []| given }
      image.define_singleton_method(:published_apps) { Erx::ImageApps.none }
      image.define_singleton_method(:assemble) { |doom:, **| throw :assembled, doom }
      [medium.name, catch(:assembled) { image.build_medium(directory: '/nonexistent', kind: medium, manifest_source: '') }]
    end
    assert_equal({ development: false, test: false, published: true }, asked)

    # `tools/erx pack --published` refuses before Fiasco or the kiosk builds.
    error = assert_raises(Erx::Error) do
      Erx::ProductionImage.pack_platform(root: @root, runner: @runner, compiler: '', linker: '', platform: PLATFORM,
                                         medium: kind.published)
    end
    assert_match(%r{\Athe published medium carries Doom, which is not fetched: run `tools/erx fetch --example doom`}, error.message)
    assert_empty Dir.children(@root) - ['logs']

    # The one build refuses too, whatever asked for Doom. An image builder reads the ABI
    # from its tree when made, so the tree with no fork is put in its place afterwards.
    unfetched = builder(Erx::ProductionImage::Machine.development(PLATFORM))
    unfetched.instance_variable_set(:@root, @root)
    unfetched.define_singleton_method(:domain_boots) { |_source, given: []| given }
    unfetched.define_singleton_method(:published_apps) { Erx::ImageApps.none }
    error = assert_raises(Erx::Error) do
      unfetched.build_medium(directory: File.join(@root, 'medium'), kind: kind.published, manifest_source: '')
    end
    assert_match(%r{\Athe published medium carries Doom, which is not fetched: run `tools/erx fetch --example doom`}, error.message)
    assert_empty Dir.children(@root) - ['logs']
  end

  # An image builder for machine whose runtimes are never built.
  def builder(machine)
    Erx::ProductionImage.new(root: ROOT, runner: @runner, compiler: '', linker: '', machine: machine, fiasco: Object.new,
                             runtime: nil, jit_runtime: nil)
  end
end
