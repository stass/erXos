# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/origin'

class OriginTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-origin-')
    @review = { 'default_license' => 'MIT', 'default_evidence' => 'reviewed COPYRIGHT',
                'rules' => [{ 'pattern' => 'special.c', 'license' => 'BSD-2-Clause',
                              'evidence' => 'reviewed file notice' }] }
    @origin = Erx::Origin.new(root: @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def write_origin
    @origin.write(repository: 'https://example.org/upstream', revision: '1',
                  archive_sha256: 'a' * 64, review: @review)
  end

  def write_file(path, bytes)
    File.binwrite(File.join(@directory, path), bytes)
  end

  def attribution(path, bytes:, sidecar: nil)
    Erx::Attribution.for_file(path, bytes: bytes, sidecar: sidecar, review: @review)
  end

  def test_explicit_header_precedes_reviewed_default
    result = attribution('source.c', bytes: "/* SPDX-License-Identifier: ISC */\n")
    assert_equal 'ISC', result.fetch('license')
    assert_equal 'file SPDX', result.fetch('evidence')
  end

  def test_lua_header_precedes_package_default
    result = attribution('build.lua', bytes: "-- SPDX-License-Identifier: BSD-2-Clause\n")
    assert_equal 'BSD-2-Clause', result.fetch('license')
  end

  def test_sidecar_and_reviewed_exception
    attached = attribution('data', bytes: "\0data", sidecar: "SPDX-License-Identifier: Zlib\n")
    assert_equal 'Zlib', attached.fetch('license')
    reviewed = attribution('special.c', bytes: 'no SPDX')
    assert_equal 'BSD-2-Clause', reviewed.fetch('license')
    assert reviewed.fetch('reviewed')
  end

  def test_reviewed_correction_requires_exact_upstream_declaration
    @review.fetch('rules').unshift({ 'pattern' => 'upstream.c',
                                    'declared_license' => 'GPL-2.0-only or License-Ref-kk-custom',
                                    'license' => 'GPL-2.0-only',
                                    'evidence' => 'reviewed GPL alternative in file header' })
    bytes = "/* SPDX-License-Identifier: GPL-2.0-only or License-Ref-kk-custom */\n"
    result = attribution('upstream.c', bytes: bytes)
    assert_equal 'GPL-2.0-only', result.fetch('license')
    assert result.fetch('reviewed')
    changed = bytes.sub('or License-Ref', 'or Different-Ref')
    assert_raises(Erx::Error) { attribution('upstream.c', bytes: changed) }
  end

  def test_unknown_permission_is_refused
    assert_raises(Erx::Error) do
      attribution('fixture', bytes: "# SPDX-License-Identifier: NOASSERTION\n")
    end
  end

  def test_complete_licence_expression_is_required
    ['MIT OR', 'MIT ISC', '(MIT OR ISC', 'MIT WITH (Exception)', 'NONE'].each do |expression|
      assert_raises(Erx::Error) { Erx::Attribution.validate_expression(expression) }
    end
    assert_equal '(MIT OR BSD-2-Clause) AND ISC',
                 Erx::Attribution.validate_expression('(MIT OR BSD-2-Clause) AND ISC')
  end

  def test_unmodified_inventory_passes
    write_file('source.c', "/* upstream */\nint value;\n")
    write_origin
    files = @origin.check.fetch('files')
    assert_equal Digest::SHA256.file(File.join(@directory, 'source.c')).hexdigest,
                 files.fetch('source.c').fetch('sha256')
  end

  # A copy of an imported file keeps its upstream notices, so the rule for an added
  # file refuses it. Its own row, the source's row plus copied_from, records it.
  def copy_with_row(row_change: {})
    write_file('special.c', "/* SPDX-License-Identifier: BSD-2-Clause */\nint special;\n")
    write_origin
    write_file('copy.c', File.binread(File.join(@directory, 'special.c')))
    path = File.join(@directory, 'ORIGIN.md')
    head, body = File.binread(path).split(Erx::Origin::INVENTORY_MARKER, 2)
    payload = JSON.parse(body.delete_suffix("\n```\n"))
    row = payload.fetch('files').fetch('special.c').merge('copied_from' => 'special.c').merge(row_change)
    payload.fetch('files')['copy.c'] = row
    File.binwrite(path, head + Erx::Origin::INVENTORY_MARKER + JSON.pretty_generate(payload) + "\n```\n")
  end

  def test_a_copy_without_a_row_is_refused
    write_file('special.c', "/* SPDX-License-Identifier: BSD-2-Clause */\nint special;\n")
    write_origin
    write_file('copy.c', File.binread(File.join(@directory, 'special.c')))
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/not plainly erXos's own: copy\.c/, error.message)
  end

  def test_an_unchanged_copy_with_its_row_passes
    copy_with_row
    @origin.check
  end

  def test_a_changed_copy_needs_the_change_notice
    copy_with_row
    write_file('copy.c', "/* SPDX-License-Identifier: BSD-2-Clause */\nint changed;\n")
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/lacks its erXos change notice: copy\.c/, error.message)
    write_file('copy.c', "/* Modified by erXos */\n/* SPDX-License-Identifier: BSD-2-Clause */\nint changed;\n")
    @origin.check
  end

  def test_a_copys_row_must_repeat_its_sources_row
    copy_with_row(row_change: { 'license' => 'MIT' })
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/does not repeat the row/, error.message)
  end

  def test_a_copys_row_must_name_a_source
    copy_with_row(row_change: { 'copied_from' => nil })
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_deleted_imported_file_is_not_silently_accepted
    write_file('source.c', "/* upstream */\nint value;\n")
    write_origin
    File.unlink(File.join(@directory, 'source.c'))
    error = assert_raises(Erx::Error) { @origin.check }
    assert_includes error.message, 'source.c'
  end

  def test_deleted_file_with_an_explicit_change_record_is_rejected
    write_file('source.c', "/* upstream */\n")
    write_origin
    bytes = "\0generated".b
    write_file('generated.bin', bytes)
    replace_inventory do |payload|
      payload.fetch('changes')['generated.bin'] = {
        'sha256' => Digest::SHA256.hexdigest(bytes), 'license' => 'MIT',
        'evidence' => 'generated fixture data'
      }
      payload
    end
    assert @origin.check
    File.unlink(File.join(@directory, 'generated.bin'))
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_link_marker_bytes_do_not_make_a_regular_file_an_imported_link
    write_file('target.c', "/* upstream */\n")
    link = File.join(@directory, 'link.c')
    File.symlink('target.c', link)
    write_origin
    File.unlink(link)
    File.binwrite(link, "symlink\0target.c")
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_changed_source_requires_notice
    write_file('source.c', "int value;\n")
    write_origin
    write_file('source.c', "int changed;\n")
    assert_raises(Erx::Error) { @origin.check }
    write_file('source.c', "/* Modified by erXos */\nint changed;\n")
    assert @origin.check
  end

  # A block comment that closes on its own line, as an imported licence header
  # does, leaves nothing of that line to read: the check answers, not crashes.
  def test_a_header_comment_closed_on_its_own_line_is_read
    write_file('source.c', "int value;\n")
    write_origin
    write_file('source.c', "/*\n * Licence.\n */\nint changed;\n")
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/lacks its erXos change notice/, error.message)
    write_file('source.c', "/*\n * Licence.\n */\n// Modified by erXos\nint changed;\n")
    assert @origin.check
  end

  def test_new_source_requires_erxos_notice
    write_origin
    write_file('new.c', "int value;\n")
    assert_raises(Erx::Error) { @origin.check }
    write_file('new.c', "// #{HOLDER}\n/* SPDX-License-Identifier: BSD-2-Clause */\nint value;\n")
    assert @origin.check
  end

  HOLDER = 'Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>'
  NOTICE = "// #{HOLDER}\n// SPDX-License-Identifier: BSD-2-Clause\n"

  def assert_not_an_addition(bytes)
    write_file('new.c', bytes)
    error = assert_raises(Erx::Error, bytes) { @origin.check }
    assert_match(/not plainly erXos's own: new\.c/, error.message)
  end

  # A new file is attributed from its own header, so the file must declare the
  # project's licence and no other, in any form a reader could take for one.
  def test_new_source_may_declare_only_the_project_licence
    write_origin
    ["// #{HOLDER}\n/* SPDX-License-Identifier: BSD-2-Clause-Patent */\n",
     "// #{HOLDER}\n/* SPDX-License-Identifier: BSD-2-Clause AND GPL-2.0-only */\n",
     "// #{HOLDER}\n/* not SPDX-License-Identifier: BSD-2-Clause */\n",
     "#{NOTICE}/* SPDX-License-Identifier: GPL-2.0-only */\n",
     "#{NOTICE}int value;\n// SPDX-License-Identifier: GPL-2.0-only\n",
     "#{NOTICE}int value;\n" + ("/* padding */\n" * 1000) + "// SPDX-License-Identifier: GPL-2.0-only\n",
     "// #{HOLDER}\n/* SPDX-License-Identifier: BSD-2-Clause */ /* SPDX-License-Identifier: GPL-2.0-only */\n",
     "// #{HOLDER}\n/* SPDX-License-Identifier: BSD-2-Clause */\r/* SPDX-License-Identifier: GPL-2.0-only */\r",
     "#{NOTICE}<!-- SPDX-License-Identifier: GPL-2.0-only -->\n",
     "#{NOTICE}dnl SPDX-License-Identifier: GPL-2.0-only\n",
     "#{NOTICE}int value; /* SPDX-License-Identifier: GPL-2.0-only */\n",
     "#{NOTICE}// spdx-license-identifier: GPL-2.0-only\n",
     "#{NOTICE}// SPDX-License-Identifier : GPL-2.0-only\n"].each { |bytes| assert_not_an_addition(bytes) }
  end

  # An unedited third-party file can already declare BSD-2-Clause, and that
  # licence requires its holder's notice kept: another holder's name, or none,
  # means the file is not erXos's own.
  def test_new_source_may_name_only_the_project_as_copyright_holder
    write_origin
    ["/* SPDX-License-Identifier: BSD-2-Clause */\nint value;\n",
     "// Copyright (c) 1990 The Regents\n// SPDX-License-Identifier: BSD-2-Clause\n",
     "#{NOTICE}int value;\n/* Copyright (c) 1990 The Regents */\n",
     "#{NOTICE}/* COPYRIGHT 1990 The Regents */\n"].each { |bytes| assert_not_an_addition(bytes) }
  end

  def test_notice_below_the_header_comment_does_not_make_an_addition
    write_origin
    assert_not_an_addition("int value;\n#{NOTICE}")
  end

  def test_new_binary_is_not_an_addition_even_with_its_nul_past_the_header_window
    write_origin
    assert_not_an_addition("#{NOTICE}#{'x' * 9000}\0".b)
  end

  def test_a_crlf_addition_is_read_like_any_other
    write_origin
    write_file('new.c', "// #{HOLDER}\r\n// SPDX-License-Identifier: BSD-2-Clause\r\nint value;\r\n")
    assert @origin.check
  end

  def test_excluded_path_does_not_come_back_as_an_addition
    File.write(File.join(@directory, 'kept.c'), 'int kept;')
    @origin.write(repository: 'https://example.org/upstream', revision: '1', archive_sha256: 'a' * 64, review: @review,
                  exclusions: [{ 'path' => 'removed.c', 'reason' => 'licence' }, { 'path' => 'gone', 'reason' => 'licence' }])
    FileUtils.mkdir_p(File.join(@directory, 'gone'))
    ['removed.c', 'gone/inner.c'].each do |path|
      write_file(path, "#{NOTICE}int value;\n")
      error = assert_raises(Erx::Error) { @origin.check }
      assert_match(/restores a path its import excluded/, error.message)
      File.unlink(File.join(@directory, path))
    end
    write_file('removed.c.new', "#{NOTICE}int value;\n")
    assert @origin.check
  end

  def test_preserved_upstream_unicode_and_ascii_addition
    original = "/* Universit\xc3\xa4t */\n".b
    write_file('source.c', original)
    write_origin
    write_file('source.c', "/* Modified by erXos */\n".b + original + "int value;\n".b)
    assert @origin.check
    write_file('source.c', "/* Modified by erXos */\n".b + original + "/* \xc3\xa9 */\n".b)
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_origin_output_symlink_cannot_write_outside_import
    root = File.join(@directory, 'import')
    Dir.mkdir(root)
    outside = File.join(@directory, 'outside')
    File.symlink(outside, File.join(root, 'ORIGIN.md'))
    origin = Erx::Origin.new(root: root)
    assert_raises(Erx::Error) do
      origin.write(repository: 'https://example.org/upstream', revision: '1',
                   archive_sha256: 'a' * 64, review: @review)
    end
    refute File.exist?(outside)
  end

  def test_escaping_import_link_is_not_provenance
    File.symlink('../outside', File.join(@directory, 'link'))
    assert_raises(Erx::Error) { write_origin }
  end

  def replace_inventory
    path = File.join(@directory, 'ORIGIN.md')
    prose, _marker, data = File.read(path).partition(Erx::Origin::INVENTORY_MARKER)
    payload = JSON.parse(data.delete_suffix("\n```\n"))
    changed = yield payload
    File.write(path, prose + Erx::Origin::INVENTORY_MARKER + JSON.pretty_generate(changed) + "\n```\n")
  end

  def test_matching_file_hash_without_attribution_is_refused
    write_file('source.c', "int value;\n")
    write_origin
    replace_inventory do |payload|
      payload.fetch('files').fetch('source.c').delete('license')
      payload
    end
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_malformed_inventory_top_level_is_a_domain_error
    write_origin
    replace_inventory { |_payload| [] }
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_invalid_utf8_inventory_is_a_domain_error
    write_origin
    path = File.join(@directory, 'ORIGIN.md')
    bytes = File.binread(path).sub(('a' * 64).b, ("\xff" + 'a' * 63).b)
    File.binwrite(path, bytes)
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_an_erxos_xml_file_is_an_addition_after_its_xml_declaration
    notice = "<!--\n  Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n  SPDX-License-Identifier: BSD-2-Clause\n-->\n"
    assert Erx::Attribution.erxos_addition?("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + notice + "<device/>\n")
    assert Erx::Attribution.erxos_addition?(notice + "<device/>\n")
    refute Erx::Attribution.erxos_addition?("<?xml version=\"1.0\"?>\n<device/>\n<!-- " + notice + " -->\n")
    refute Erx::Attribution.erxos_addition?("<?xml version=\"1.0\"?>\n<?xml version=\"1.0\"?>\n" + notice)
    one_line = "<!-- Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n     SPDX-License-Identifier: BSD-2-Clause -->\n"
    assert Erx::Attribution.erxos_addition?(one_line + "<device/>\n")
    assert Erx::Attribution.erxos_addition?("<!-- SPDX-License-Identifier: BSD-2-Clause -->\n<!-- Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com> -->\n<device/>\n")
  end

  # A comment ends at its `-->`: a notice in the document body, which is no comment, is not a header.
  def test_an_xml_comment_ends_at_its_close
    body = "Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\nSPDX-License-Identifier: BSD-2-Clause\n"
    refute Erx::Attribution.erxos_addition?("<?xml version=\"1.0\"?>\n<!--\n x\n-->\n<device>\n" + body)
    refute Erx::Attribution.erxos_addition?("<!-- x -->\n<device>\n" + body)
  end

  def test_notice_token_in_body_string_is_not_a_header_notice
    write_file('source.c', "int value;\n")
    write_origin
    write_file('source.c', "const char *s = \"Modified by erXos\";\n")
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_non_ascii_addition_to_extensionless_build_script_is_refused
    write_file('configure', "#!/bin/sh\nexit 0\n")
    write_origin
    write_file('configure', "#!/bin/sh\n# Modified by erXos\n# \xc3\xa9\nexit 0\n".b)
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_extensionless_inherited_header_is_source
    Dir.mkdir(File.join(@directory, 'include'))
    original = "// Universit\xc3\xa4t\n".b
    write_file('include/vector', original)
    write_origin
    write_file('include/vector', "// Modified by erXos\n".b + original + "int value;\n".b)
    assert @origin.check
    write_file('include/vector', "// Modified by erXos\n".b + original + "// \xc3\xa9\n".b)
    assert_raises(Erx::Error) { @origin.check }
  end

  def test_binary_change_requires_exact_explicit_metadata
    write_file('bootstrap.beam', "\0original".b)
    write_origin
    changed = "\0changed".b
    write_file('bootstrap.beam', changed)
    assert_raises(Erx::Error) { @origin.check }
    replace_inventory do |payload|
      payload.fetch('changes')['bootstrap.beam'] = {
        'sha256' => Digest::SHA256.hexdigest(changed), 'license' => 'MIT',
        'evidence' => 'regenerated from the imported source'
      }
      payload
    end
    assert @origin.check
    write_file('bootstrap.beam', "\0other".b)
    assert_raises(Erx::Error) { @origin.check }
  end
end
