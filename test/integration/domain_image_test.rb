# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/runner'

# An image carrying a domain release, read back from its archive's index
# (docs/design-stopgap.md, "The production image"): the release is one run of whole
# entries under domains/<name>/ without the system mark, which leaves the system run
# whole, and the domain runtime image is the interpreter ERTS at task.ld's fixed
# addresses, without JIT authority or the system mark, and the BeamAsm image beside
# it is the one entry whose manifest carries ERX_IMAGE_JIT. The production image carries
# no domain release while the manifest check admits no domain row, so the image here
# goes through the same assembly with one release asked for.
#
# `make check-boot-image` runs this; it builds the native runtime, which `make check`
# does not.
class DomainImageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DIRECTORY = File.join(ROOT, 'build/domain-image')

  class << self
    attr_accessor :built
  end

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    self.class.built ||= begin
      Erx::ProductionImage.clear_directory(root: ROOT, path: DIRECTORY)
      runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
      image = Erx::ProductionImage.new(root: ROOT, runner: runner, compiler: ENV.fetch('ERX_CLANG', ''),
                                       linker: ENV.fetch('ERX_LLD', ''))
      image.send(:assemble, directory: DIRECTORY, manifest_source: File.binread(File.join(ROOT, Erx::ProductionImage::MANIFEST)),
                            added: Erx::ProductionImage.const_get(:NOTHING_ADDED), test_code: false,
                            machine: Erx::ProductionImage::DEVELOPMENT_MACHINE,
                            domains: [Erx::ReleaseFiles.domain('base', applications: Erx::ReleaseFiles::DOMAIN_BASE)])
    end
    @bytes = File.binread(self.class.built.archive)
    @entries = index(@bytes)
  end

  def index(bytes)
    header = @codec.decode_layout('erx_pack_header', bytes)
    strings = bytes.byteslice(header.fetch('strings_off'), header.fetch('strings_size'))
    Array.new(header.fetch('nentries')) do |number|
      at = header.fetch('entries_off') + number * header.fetch('entry_size')
      entry = @codec.decode_layout('erx_pack_entry', bytes.byteslice(at, header.fetch('entry_size')))
      entry.merge('path' => strings.byteslice(entry.fetch('path_off'), entry.fetch('path_len')))
    end
  end

  def system?(entry) = entry.fetch('flags').anybits?(@codec.member('entry_flags', 'system'))

  def test_the_domain_release_is_one_unmarked_run_of_whole_entries
    run = @entries.each_index.select { |number| @entries[number].fetch('path').start_with?('domains/base/') }
    refute_empty run
    assert_equal (run.first..run.last).to_a, run, 'the release is one run of the index'
    assert(run.none? { |number| system?(@entries[number]) }, 'no file of a domain release carries the system mark')
    page = @codec.constant('page_size')
    assert(run.all? { |number| (@entries[number].fetch('data_off') % page).zero? }, 'each file starts on a page of its own')
    paths = run.map { |number| @entries[number].fetch('path') }
    assert_includes paths, 'domains/base/bin/start.boot'
    assert(paths.any? { |path| path.match?(%r{\Adomains/base/lib/kernel-[0-9.]+/ebin/kernel\.app\z}) }, 'kernel.app')
    assert(paths.any? { |path| path.match?(%r{\Adomains/base/lib/stdlib-[0-9.]+/ebin/lists\.beam\z}) }, 'lists.beam')
    shipped = paths.filter_map { |path| path[%r{\Adomains/base/lib/([a-z_]+)-}, 1] }.uniq.sort
    assert_equal %w[kernel stdlib], shipped
  end

  def test_the_system_run_stays_whole
    marked = @entries.each_index.select { |number| system?(@entries[number]) }
    assert_equal (marked.first..marked.last).to_a, marked
    assert(marked.all? { |number| @entries[number].fetch('path').start_with?('system/') })
  end

  def image?(entry) = entry.fetch('kind') == @codec.member('entry_kind', 'image')

  def manifest_flags(entry)
    @codec.decode_layout('erx_image_manifest', @bytes.byteslice(entry.fetch('data_off'), entry.fetch('data_size'))).fetch('flags')
  end

  # The flags of the runtime image at path, which must be an unmarked image entry.
  def runtime_flags(path)
    entry = @entries.find { |candidate| candidate.fetch('path') == path }
    refute_nil entry, "the image carries #{path}"
    assert image?(entry)
    refute system?(entry)
    manifest_flags(entry)
  end

  def test_the_domain_runtime_is_a_fixed_interpreter_image_without_the_system_mark
    flags = runtime_flags(Erx::ProductionImage::DOMAIN_RUNTIME_PATH)
    assert flags.anybits?(@codec.member('image_flags', 'fixed')), 'task.ld gives fixed addresses'
    refute flags.anybits?(@codec.member('image_flags', 'jit')), 'the interpreter image makes no code'
  end

  def test_the_beamasm_runtime_alone_carries_the_jit_mark
    flags = runtime_flags(Erx::ProductionImage::JIT_RUNTIME_PATH)
    assert flags.anybits?(@codec.member('image_flags', 'fixed')), 'task.ld gives fixed addresses'
    jit = @entries.select { |entry| image?(entry) && manifest_flags(entry).anybits?(@codec.member('image_flags', 'jit')) }
    assert_equal [Erx::ProductionImage::JIT_RUNTIME_PATH], jit.map { |entry| entry.fetch('path') }, 'no other image makes code'
  end
end
