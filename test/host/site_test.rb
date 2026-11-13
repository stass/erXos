# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'yaml'
require 'zlib'
require_relative '../../tools/lib/erx/site'
require_relative '../../tools/lib/erx/production_image'

class SiteTest < Minitest::Test
  REPO = File.expand_path('../..', __dir__)
  COMMIT = '0123456789abcdef0123456789abcdef01234567'
  CARD_BLOCK = '<!--card--><p class="card">card {{card_file}} {{card_sha256}} {{card_download_sha256}} ' \
               '<a href="{{card_record}}">r</a></p><!--/card-->'
  INDEX = '<script src="{{terminal_js}}"></script><a href="{{source_url}}">{{source_label}}</a>'

  # A fake tree: site/ sources, a built v64 tree with its notices, an image,
  # and a card with its build record.
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
      File.binwrite(File.join(root, 'sdcard.img'), "erXos card\0" * 1000)
      write_card_record(root)
      yield root, image
    end
  end

  # A stand-in for the data partition's fresh volume (DataVolume.format): whole sectors.
  VOLUME = ('erXos littlefs volume' * 400).byteslice(0, 8192)

  # The card's build record in root, as BootPartition writes one: the source it was
  # built from, the card by its SHA-256, and inputs.
  def write_card_record(root, sha256: Digest::SHA256.file(File.join(root, 'sdcard.img')).hexdigest,
                        source: { 'commit' => COMMIT, 'dirty' => false },
                        inputs: { 'board_tree' => { 'dtc' => 'Version: DTC 1.7.2' } })
    record = { 'source' => source, 'artifact' => { 'path' => 'sdcard.img', 'sha256' => sha256 }, 'inputs' => inputs }
    File.write(File.join(root, 'sdcard.img.receipt.json'), JSON.generate(record))
  end

  def inventory(root, image, ref: COMMIT, card: File.join(root, 'sdcard.img'),
                card_record: File.join(root, 'sdcard.img.receipt.json'))
    Erx::Site.inventory(root:, v64: File.join(root, 'v64'), image:, card:, card_record:,
                        source: Erx::Site.source(ref), disk: Erx::Site.fresh_medium(volume: VOLUME))
  end

  # The page boots the production image, whose manifest's root_memory needs the
  # development machine's RAM, so terminal.js gives the guest exactly that much.
  def test_the_page_gives_the_guest_the_development_machines_ram
    script = File.read(File.join(REPO, 'site/terminal.js'))
    assert_equal [Erx::Platform.development(REPO).memory_mib.to_s], script.scan(/^const RAM_MIB = ([0-9]+);$/).flatten
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

  # The card is published gzip-compressed under its digest's name, its record beside
  # it, and the page names both with the card's and the download's SHA-256.
  def test_publish_offers_the_card_and_its_record
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      File.write(File.join(root, 'site/index.html'),
                 '<a href="{{card_file}}">{{card_sha256}} {{card_download_sha256}}</a><a href="{{card_record}}">r</a>')
      card = Erx::Site.publish(inventory(root, image), out:).fetch(:card)
      sha256 = Digest::SHA256.file(File.join(root, 'sdcard.img')).hexdigest

      assert_equal "sdcard-#{sha256[0, 16]}.img.gz", card.fetch(:file)
      assert_equal File.binread(File.join(root, 'sdcard.img')), Zlib.gunzip(File.binread(File.join(out, card.fetch(:file))))
      assert_equal Digest::SHA256.file(File.join(out, card.fetch(:file))).hexdigest, card.fetch(:compressed_sha256)
      # The record published is the one checked, as parsed, not a second read of its file.
      assert_equal "#{JSON.pretty_generate(JSON.parse(File.read(File.join(root, 'sdcard.img.receipt.json'))))}\n",
                   File.read(File.join(out, card.fetch(:record)))
      assert_equal "sdcard-#{sha256[0, 16]}.img.receipt.json", card.fetch(:record)
      assert_equal "<a href=\"#{card.fetch(:file)}\">#{sha256} #{card.fetch(:compressed_sha256)}</a>" \
                   "<a href=\"#{card.fetch(:record)}\">r</a>", File.read(File.join(out, 'index.html'))
      assert_equal card, JSON.parse(File.read(File.join(out, 'boot.json')), symbolize_names: true).fetch(:card)
    end
  end

  # A local preview has no card: the page's card block, boot.json's card entry
  # and the card's files are absent, and no card placeholder is left.
  def test_a_build_without_a_card_has_no_card_section
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      File.write(File.join(root, 'site/index.html'),
                 "<p>image</p>\n#{CARD_BLOCK}\n<p>end</p>\n")
      manifest = Erx::Site.publish(inventory(root, image, card: nil, card_record: nil), out:)

      refute manifest.key?(:card)
      refute JSON.parse(File.read(File.join(out, 'boot.json'))).key?('card')
      assert_equal "<p>image</p>\n<p>end</p>\n", File.read(File.join(out, 'index.html'))
      assert_empty Dir.glob(File.join(out, 'sdcard*'))
      # With a card, the block stays, without its markers.
      Erx::Site.publish(inventory(root, image), out:)
      assert_match(%r{<p>image</p>\n<p class="card">card sdcard-[0-9a-f]{16}\.img\.gz [^\n]*</p><p>end</p>\n}, File.read(File.join(out, 'index.html')))
    end
  end

  def test_the_page_without_a_card_leaves_no_placeholder
    page = Erx::Site.render_index(File.read(File.join(REPO, 'site/index.html')), terminal: 't.js',
                                  source: Erx::Site.source(COMMIT), card: nil)
    refute_includes page, '{{'
    refute_includes page, 'card-download'
    refute_includes page, 'For a Raspberry Pi 4'
    refute_includes page, '<!--card'
  end

  # A card placeholder outside the card block is a bug in the page, not a gap in the output.
  def test_a_card_placeholder_outside_the_card_block_is_refused_without_a_card
    error = assert_raises(Erx::Error) do
      Erx::Site.render_index('<a href="{{card_file}}">x</a>', terminal: 't.js', source: Erx::Site.source(COMMIT),
                                                               card: nil)
    end
    assert_match(/card_file/, error.message)
  end

  # Only an absent card (nil) is a build without one; a card that is named and
  # missing, or whose record is not its own, is still refused.
  def test_a_named_card_that_is_missing_is_still_refused
    with_inputs do |root, image|
      File.delete(File.join(root, 'sdcard.img'))
      error = assert_raises(Erx::Error) { inventory(root, image) }
      assert_match(/sdcard\.img/, error.message)
      error = assert_raises(Erx::Error) { inventory(root, image, card: nil) }
      assert_match(/both or neither/, error.message)
    end
  end

  # --no-card is for local previews and cannot be combined with a card's options.
  def test_build_site_refuses_no_card_with_a_card_option
    _out, err, status = Open3.capture3(RbConfig.ruby, File.join(REPO, 'tools/build_site.rb'), '--no-card',
                                       '--card', '/nonexistent', '--v64', '/nonexistent',
                                       '--out', '/nonexistent/out', stdin_data: '')
    assert_equal 2, status.exitstatus
    assert_match(/--no-card/, err)
  end

  # The publishing workflow always passes a card and never --no-card.
  def test_the_workflow_never_builds_without_a_card
    workflow = File.read(File.join(REPO, '.github/workflows/site.yml'))
    refute_match(/no-card|no_card/, workflow)
    commands = workflow.lines.grep(/^\s*run: ruby tools\/build_site\.rb/)
    assert_equal 1, commands.size
    assert_match(/--card sdcard\.img --card-record sdcard\.img\.receipt\.json/, commands.first)
  end

  # Seeded faults: a record of another card (one digit of its SHA-256 off), one that
  # names a host's path, and one that is not JSON are refused, and nothing is built.
  def test_a_card_whose_record_is_not_its_own_is_refused
    with_inputs do |root, image|
      sha256 = Digest::SHA256.file(File.join(root, 'sdcard.img')).hexdigest
      { 'another card' => -> { write_card_record(root, sha256: sha256.sub(/\A./) { |digit| digit == '0' ? '1' : '0' }) },
        'a host path' => -> { write_card_record(root, inputs: { 'dtc' => '/Users/someone/bin/dtc' }) },
        'not JSON' => -> { File.write(File.join(root, 'sdcard.img.receipt.json'), '{') } }.each do |fault, seed|
        seed.call
        assert_raises(Erx::Error, fault) { inventory(root, image) }
      end
      refute File.exist?(File.join(root, 'build/site'))
    end
  end

  # The page links the source the card was built from, so the card's record must name
  # that commit, clean. Seeded faults: a record of another commit (one digit off), of a
  # tree with changes, with no source (a tree that was no checkout), or with a commit
  # that is not one, and a page that links a tag the record cannot be checked against,
  # are refused, and nothing is built.
  def test_a_card_not_built_from_the_linked_source_is_refused
    with_inputs do |root, image|
      other = COMMIT.sub(/\A./) { |digit| digit == '0' ? '1' : '0' }
      { 'another commit' => -> { write_card_record(root, source: { 'commit' => other, 'dirty' => false }) },
        'a dirty tree' => -> { write_card_record(root, source: { 'commit' => COMMIT, 'dirty' => true }) },
        'dirty not false' => -> { write_card_record(root, source: { 'commit' => COMMIT }) },
        'no source' => -> { write_card_record(root, source: nil) },
        'a short commit' => -> { write_card_record(root, source: { 'commit' => COMMIT[0, 12], 'dirty' => false }) } }
        .each do |fault, seed|
        seed.call
        assert_raises(Erx::Error, fault) { inventory(root, image) }
      end
      write_card_record(root)
      error = assert_raises(Erx::Error) { inventory(root, image, ref: 'v1.0') }
      assert_match(/40-hex commit/, error.message)
      refute File.exist?(File.join(root, 'build/site'))
    end
  end

  # The disk is the fresh medium's partition table and data volume, published
  # as their bytes and the extents they fill, and boot.json names it with its
  # digest.
  def test_publish_writes_the_fresh_medium_as_its_extents
    with_inputs do |root, image|
      out = File.join(root, 'build/site')
      disk = Erx::Site.publish(inventory(root, image), out:).fetch(:disk)
      content = File.binread(File.join(out, disk.fetch(:file)))

      assert_match(/\Adisk-[0-9a-f]{16}\.bin\z/, disk.fetch(:file))
      assert_equal Digest::SHA256.hexdigest(content), disk.fetch(:sha256)
      assert_equal content.bytesize, disk.fetch(:bytes)
      data_sectors = Erx::MediumImage.constant('data_sectors_min')
      assert_equal Erx::MediumImage.sectors(data_sectors:) * 512, disk.fetch(:capacity)
      # The medium writer's own image holds the published bytes at each extent.
      Dir.mktmpdir('erx-medium-') do |directory|
        medium = Erx::MediumImage.create(directory:, name: 'medium.img', data_sectors:,
                                         pieces: { Erx::MediumImage.constant('data_start') => VOLUME })
        assert_equal disk.fetch(:capacity), File.size(medium)
        at = 0
        File.open(medium, 'rb') do |input|
          disk.fetch(:extents).each do |offset, length|
            assert_equal content.byteslice(at, length), input.pread(length, offset), "the extent at #{offset}"
            at += length
          end
        end
        assert_equal content.bytesize, at
      end
      assert_equal [0, Erx::MediumImage.constant('extended_start'), Erx::MediumImage.constant('data_ebr')]
                     .map { |sector| [sector * 512, 512] } + [[Erx::MediumImage.constant('data_start') * 512, VOLUME.bytesize]],
                   disk.fetch(:extents)
    end
  end

  def test_a_disk_joins_adjacent_pieces_and_refuses_bad_ones
    sector = ->(byte) { byte.chr * 512 }
    disk = Erx::Site.disk(pieces: { 4 => sector.(0x62), 0 => sector.(0x61), 5 => sector.(0x63) * 2 }, capacity: 512 * 8)
    assert_equal [[0, 512], [2048, 1536]], disk.extents
    assert_equal "#{sector.(0x61)}#{sector.(0x62)}#{sector.(0x63) * 2}", disk.content
    assert_equal [[3584, 512]], Erx::Site.disk(pieces: { 7 => sector.(0) }, capacity: 4096).extents, 'a piece may end the disk'

    [{ pieces: { 0 => 'short' }, capacity: 4096 },
     { pieces: { 0 => sector.(0), 1 => sector.(0) * 2, 2 => sector.(0) }, capacity: 4096 },
     { pieces: { nil => sector.(0) }, capacity: 4096 },
     { pieces: { 0 => 1 }, capacity: 4096 },
     { pieces: { 0 => '' }, capacity: 4096 },
     { pieces: { 7 => sector.(0) * 2 }, capacity: 4096 },
     { pieces: { -1 => sector.(0) }, capacity: 4096 },
     { pieces: { 0 => sector.(0) * 2, 1 => sector.(0) }, capacity: 4096 },
     { pieces: {}, capacity: 1000 },
     { pieces: {}, capacity: 0 }].each do |bad|
      assert_raises(Erx::Error, bad.inspect) { Erx::Site.disk(**bad) }
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

  # The page's "Ready" waits for the banner of a session's command shell or the
  # console's line for a login that did not start, so a rewording of either must
  # fail here and not leave a page that never readies.
  def test_ready_marker_names_the_lines_the_guest_writes
    terminal = File.read(File.join(REPO, 'site/terminal.js'))
    shell = File.read(File.join(REPO, 'erlang/apps/erx_shell/src/erx_shell.erl'))
    console = File.read(File.join(REPO, 'erlang/apps/erx/src/erx_console.erl'))
    ready = terminal.match(%r{marker: /(rc: [^|/]*)\|(erx_console: [^|/]*)/})
    refute_nil ready, 'the last milestone waits for a session shell banner or the failed login line'
    assert_includes shell, "-define(BANNER, <<\"#{ready[1]}\\n\">>)", 'erx_shell.erl writes the session banner'
    assert_includes console, "\"#{ready[2]}: ~0P\"", "erx_console.erl writes the line #{ready[2].inspect}"
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

  # The page's own index.html names only placeholders render_index fills.
  def test_the_page_fills_every_placeholder
    page = Erx::Site.render_index(File.read(File.join(REPO, 'site/index.html')), terminal: 't.js',
                                  source: Erx::Site.source(COMMIT),
                                  card: { file: 'c.img.gz', record: 'r', sha256: 's', compressed_sha256: 'z' })
    refute_includes page, '{{'
    assert_includes page, 'href="c.img.gz"'
  end

  def test_an_unknown_index_placeholder_is_refused
    error = assert_raises(Erx::Error) do
      Erx::Site.render_index('{{nope}}', terminal: 't.js', source: Erx::Site.source(COMMIT),
                                          card: { file: 'c', record: 'r', sha256: 's', compressed_sha256: 'z' })
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
    good = { 'IMAGE_SHA256' => 'a' * 64, 'IMAGE_SOURCE' => COMMIT, 'CARD_SHA256' => 'b' * 64,
             'CARD_RECORD_SHA256' => 'c' * 64 }
    assert system(good, 'bash', '-e', '-c', check, out: File::NULL, err: File::NULL)
    [{ 'IMAGE_SHA256' => 'A' * 64 }, { 'IMAGE_SHA256' => "#{'a' * 64}\nb" }, { 'IMAGE_SHA256' => 'a' * 63 },
     { 'CARD_SHA256' => 'b' * 63 }, { 'CARD_SHA256' => '' }, { 'CARD_RECORD_SHA256' => 'C' * 64 },
     { 'CARD_RECORD_SHA256' => '' }, { 'IMAGE_SOURCE' => '../x' }, { 'IMAGE_SOURCE' => 'v1 x' }, { 'IMAGE_SOURCE' => '' }].each do |bad|
      refute system(good.merge(bad), 'bash', '-e', '-c', check, out: File::NULL, err: File::NULL), bad.inspect
    end
    # Each download is checked against its digest, the card's record as well as the card,
    # and capped in size.
    { 'Download the erXos image' => 1, "Download the Raspberry Pi 4's card" => 2 }.each do |name, checked|
      run = steps.find { |step| step['name'] == name }.fetch('run')
      assert_equal checked, run.scan('sha256sum --check --strict').size, name
      assert_equal run.scan('curl ').size, run.scan('--max-filesize').size, name
    end
  end
end
