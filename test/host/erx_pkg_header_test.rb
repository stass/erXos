# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/app_pack'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/fuzz/package_seeds'
require_relative '../fixtures/elf_fixture'

# Runs the EUnit cases of the package decoder, erx_pkg_header, and of the hash tree's
# layout, erx_verity_tree (test/erlang/erx_pkg_header_tests.erl), and of the packages the
# packer writes (test/erlang/erx_app_pack_tests.erl), compiled from source with warnings
# as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
#
# The decoder's files are written here through the packer's header encoder
# (Erx::PackageSeeds): two well-formed packages, each decoded whole, and one file for each
# of the decoder's checks, wrong in a way only that check catches, with the answer it must
# give. The packer's cases are two sample apps, an Erlang one and a native one, packed by
# Erx::AppPack with fsimg and a signing key made for the run, with an SDK that holds the
# file check's modules alone, compiled here.
class ErxPkgHeaderTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[erlang/apps/erx/src/erx_pkg_header.erl otp/erts/preloaded/src/erx_verity_tree.erl
               build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl erlang/apps/erx/src/erx_abi_reader.erl
               test/erlang/host_bytes/erx_bytes.erl
               test/erlang/erx_pkg_header_tests.erl test/erlang/erx_app_pack_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  Seeds = Erx::PackageSeeds
  # An Erlang term the cases files spell: a tuple, and a reader refusal, which the EUnit
  # case matches by the reader's reason alone.
  Tuple = Data.define(:items)
  Refused = Data.define(:reason)

  # The sample apps: each app's files, app.txt first, and the header fields its package
  # must decode to beside its signer's key. share/data.bin is long enough that the Erlang
  # app's image takes more than 128 blocks, so its tree has two levels, whose order the
  # check sees; the native app's image is a few blocks, a tree of one level. Its program
  # is a minimal executable the loader accepts, since the packer plans it as the loader
  # will and refuses anything else.
  ERLANG_APP = { 'app.txt' => "app hello\n  needs display data\n  gatt nus\n  applications erx_hello\n" \
                              "  license \"BSD-2-Clause\"\n  version 2\n",
                 'lib/erx_hello/ebin/erx_hello.app' => "{application, erx_hello, [{modules, []}]}.\n",
                 'lib/erx_hello/ebin/erx_hello.beam' => 'not compiled',
                 'lib/erx_hello/priv/greeting.txt' => "hello\n",
                 'share/data.bin' => (0...540_000).map { |index| (index % 251).chr }.join }.freeze
  NATIVE_APP = { 'app.txt' => "app tiny\n  memory 8388608\n  program \"bin/tiny\" \"-v\" \"\"\n",
                 'bin/tiny' => ElfFixture.valid,
                 'share/words' => "one\ntwo\n" * 1500 }.freeze
  PACKED = [['hello.app', ERLANG_APP, { name: 'hello', arch: Seeds::ARCH, needs: %w[display data], gatt: %w[nus],
                                        start: Tuple.new([:applications, %w[erx_hello]]), license: 'BSD-2-Clause',
                                        version: 2, memory: 67_108_864 }],
            ['tiny.app', NATIVE_APP, { name: 'tiny', arch: Seeds::ARCH, needs: [], gatt: [],
                                       start: Tuple.new([:program, 'bin/tiny', ['-v', '']]), license: '',
                                       version: 1, memory: 8_388_608 }]].freeze

  def test_decoder_cases_pass_under_eunit
    files = cases.to_h { |sample, _answer| ["#{sample.name}.bin", sample.prefix] }
    lines = cases.map { |sample, answer| "{\"#{sample.name}\", #{sample.length}, #{term(answer)}}.\n" }
    output, status = eunit(:erx_pkg_header_tests, files.merge('cases.term' => lines.join))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_packed_apps_decode_sign_and_verify_under_eunit
    key = OpenSSL::PKey.generate_key('ED25519')
    files = Dir.mktmpdir('erx-app-pack-test') do |work|
      File.write(File.join(work, 'signing.pem'), key.private_to_pem)
      signer = Erx::AppPackage::Signer.read(File.join(work, 'signing.pem'))
      runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
      sdk = file_check_sdk(File.join(work, 'sdk'))
      PACKED.to_h do |name, app, _fields|
        directory = File.join(work, File.basename(name, '.app'))
        app.each do |path, bytes|
          FileUtils.mkdir_p(File.dirname(File.join(directory, path)))
          File.binwrite(File.join(directory, path), bytes)
        end
        path = Erx::AppPack.pack(directory: directory, sdk: sdk, signer: signer, output_directory: work, runner: runner,
                                 root: ROOT)
        assert_equal name, File.basename(path)
        [name, File.binread(path)]
      end
    end
    lines = PACKED.map { |name, _app, fields| "{\"#{name}\", #{term(fields.merge(key: key.raw_public_key))}}.\n" }
    other = OpenSSL::PKey.generate_key('ED25519').raw_public_key
    output, status = eunit(:erx_app_pack_tests, files.merge('packed.term' => lines.join, 'other_key.bin' => other))
    assert status.success?, output
    assert_match(/^  2 tests passed\./, output)
  end

  private

  def block = Seeds.block

  def erlang(name = 'erlang', **options) = Seeds.sample(name, declaration: Seeds::ERLANG, image_blocks: 3, tree_blocks: 1, **options)

  def cases
    @cases ||= begin
      accepted = [[erlang, expected(Seeds::ERLANG, start: Tuple.new([:applications, %w[erx_dashboard erx_charts]]))],
                  [Seeds.sample('native', declaration: Seeds::NATIVE, image_blocks: 3, tree_blocks: 1),
                   expected(Seeds::NATIVE, start: Tuple.new([:program, 'bin/doom', ['-iwad', '', '/app/share/freedoom1.wad']]))]]
      long_read = erlang('long_read', prefix_edit: ->(bytes) { bytes + ("\xff".b * block) })
      accepted + [[long_read, accepted.first.last]] + refusals + cuts
    end
  end

  # A native program whose path would name something outside the image once joined to
  # /app: up out of it, absolute, or through an empty or `.` name. The reader refuses each
  # as a string outside its class, so no app record names one.
  def program_escapes
    %w[bin/../../bin/sh /bin/sh bin//sh bin/./sh bin/].each_with_index.map do |path, index|
      declaration = Seeds::NATIVE.with(start: Erx::AppPackage::Program.new(path: path, args: []))
      [Seeds.sample("escape_#{index}", declaration: declaration, image_blocks: 3, tree_blocks: 1),
       header(Refused.new(:string_class))]
    end
  end

  # One file for each check, the first that fails answering.
  def refusals
    too_large = Seeds.codec.constant('pkg_bytes_max') + 1
    [[erlang('too_large', length_edit: ->(_) { too_large }), error(Tuple.new([:too_large, too_large]))],
     [erlang('magic', header_edit: ->(bytes) { bytes.dup.tap { |copy| copy.setbyte(0, 0) } }), header(Refused.new(:value))],
     [erlang('version', edits: ->(values) { values.merge('version' => 2) }), header(Refused.new(:value))],
     [erlang('header_past_file', length_edit: ->(_) { Seeds.codec.layout_size('erx_pkg_header') + 1 }),
      header(Refused.new(:length))],
     [erlang('seal_not_at_end', edits: ->(values) { values.merge('header_length' => values['header_length'] + 1) },
                                header_edit: ->(bytes) { bytes + "\0".b }), header(Refused.new(:trailing))],
     [erlang('both_starts', edits: ->(values) { values.merge('program' => values['name']) }), header(Refused.new(:inactive))],
     *program_escapes,
     [erlang('header_past_max', edits: ->(values) { values.merge('header_length' => Seeds.header_max + 1) },
                                length_edit: ->(_) { 2 * Seeds.header_max }), header(Refused.new(:length))],
     # A read past the header's boundary but short of the bytes the decoder reads.
     [Seeds.sample('short_read', declaration: Seeds::ERLANG, image_blocks: 2, tree_blocks: 1,
                                 prefix_edit: ->(bytes) { bytes.byteslice(0, 2 * block) }), header(:short)],
     [erlang('short', length_edit: ->(_) { block - 1 }), header(:short)],
     [erlang('padding', prefix_edit: ->(bytes) { bytes.dup.tap { |copy| copy.setbyte(block - 1, 1) } }), header(:padding)],
     [erlang('tree_one_more', tree_blocks: 2), header(Tuple.new([:tree, 2, 1]))],
     [Seeds.sample('tree_one_less', declaration: Seeds::ERLANG, image_blocks: 129, tree_blocks: 2),
      header(Tuple.new([:tree, 2, 3]))],
     [erlang('one_block_short', length_edit: ->(length) { length - block }), error(Tuple.new([:length, 4 * block, 5 * block]))],
     [erlang('one_byte_long', length_edit: ->(length) { length + 1 }), error(Tuple.new([:length, (5 * block) + 1, 5 * block]))],
     # The tree over 2^32 - 1 blocks: 33554432 + 262144 + 2048 + 16 + 1 blocks.
     [Seeds.sample('image_past_file', declaration: Seeds::ERLANG, image_blocks: 0xffffffff, tree_blocks: 33_818_641,
                                      length_edit: ->(_) { 5 * block }),
      error(Tuple.new([:length, 5 * block, block * (1 + 0xffffffff + 33_818_641)]))]]
  end

  # The header cut at each field of its fixed part: the reader finds too few bytes.
  def cuts
    Seeds.codec.schema.types.fetch('erx_pkg_header').fields.map do |field|
      [erlang("cut_#{field.name}", length_edit: ->(_) { field.offset }), header(Refused.new(:truncated))]
    end
  end

  def expected(declaration, start:)
    Tuple.new([:ok, { name: declaration.name, abi_version: Seeds.codec.abi_version, arch: Seeds::ARCH,
                      version: declaration.version, memory: declaration.memory, needs: declaration.needs,
                      gatt: declaration.gatt,
                      start: start, license: declaration.license, key: Seeds::SIGNER.public_key,
                      signature: Seeds::SIGNER.signature,
                      header_length: Seeds.header(declaration, image_blocks: 3, tree_blocks: 1).bytesize,
                      layout: { image_offset: block, image_length: 3 * block, tree_offset: 4 * block,
                                tree_length: block, salt: Seeds::SALT, root_hash: Seeds::ROOT_HASH } }])
  end

  def header(reason) = error(Tuple.new([:header, reason]))
  def error(reason) = Tuple.new([:error, reason])

  def term(value)
    case value
    in Tuple(items:) then "{#{items.map { |item| term(item) }.join(', ')}}"
    in Refused(reason:) then "{refused, #{reason}}"
    in Symbol then value.to_s
    in Integer then value.to_s
    in String then "<<#{value.bytes.join(',')}>>"
    in Array then "[#{value.map { |item| term(item) }.join(', ')}]"
    in Hash then "\#{#{value.map { |key, item| "#{key} => #{term(item)}" }.join(', ')}}"
    end
  end

  # An SDK whose one application holds the file check's modules and erx_bytes for stock.
  def file_check_sdk(root)
    ebin = File.join(root, 'erlang/lib/erx/ebin')
    FileUtils.mkdir_p(ebin)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', ebin,
                                     *SOURCES.reject { it.include?('_tests.erl') }, stdin_data: '')
    assert status.success?, output
    Erx::AppPack::Sdk.new(root: root, erlc: ENV.fetch('ERX_ERLC'))
  end

  # Writes files (each name's bytes) into a directory ERX_PKG_CASES names and runs module's
  # EUnit cases there.
  def eunit(module_name, files)
    Dir.mktmpdir('erx-pkg-header-test') do |work|
      files.each { |name, bytes| File.binwrite(File.join(work, name), bytes) }
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, *SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_PKG_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', "eunit:test(#{module_name}, [verbose]), halt().",
                      stdin_data: '')
    end
  end
end
