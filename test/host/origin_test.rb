# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/origin'

class OriginTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-origin-')
    @review = { 'import' => 'fixture', 'default_license' => 'MIT', 'default_evidence' => 'reviewed COPYRIGHT',
                'rules' => [{ 'files' => { 'special.c' => Digest::SHA256.hexdigest(GPL_LINE) }, 'license' => 'BSD-2-Clause',
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

  def attribution(path, bytes:, sidecar: nil, notices: Erx::Attribution.listed_notices)
    Erx::Attribution.for_file(path, bytes: bytes, sidecar: sidecar, review: Erx::Attribution.review(@review),
                                    notices: notices)
  end

  # A notice table listing the one notice block of each file's bytes.
  def self.table_of(licenses, import = 'fixture')
    licenses.to_h do |bytes, license|
      blocks = Erx::Attribution.notice_blocks(bytes).map(&:text).grep(Erx::Attribution::LICENSE_MARK)
      raise "#{blocks.size} notice blocks" unless blocks.size == 1

      [Digest::SHA256.hexdigest(blocks.first),
       Erx::Attribution::Notice.new(license: license, imports: license == 'POINTER' ? [import] : [])]
    end
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
    reviewed = attribution('special.c', bytes: GPL_LINE)
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
    assert_equal UNRECOGNIZED, attribution('upstream.c', bytes: changed).fetch('license')
  end

  # Made-up notices, and forms that must stay unknown rather than fall to
  # the reviewed default: a permissive license is read only from a notice
  # block the table lists (LISTED below), a GNU one sentence by sentence,
  # and any other block holding a license word leaves the file unrecognised.
  def self.comment(text, leader: ' * ') = "/*\n#{text.lines.map { |line| "#{leader}#{line}" }.join}\n */\n"

  MIT_TEXT = <<~TEXT
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.
  TEXT
  MIT_DISCLAIMER = <<~TEXT
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY.
  TEXT
  BSD_CONDITIONS = <<~TEXT
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
  TEXT
  BSD_ENDORSE = <<~TEXT
    3. Neither the name of the Example Project nor the names of its
       contributors may be used to endorse or promote products derived from
       this software without specific prior written permission.
  TEXT
  BSD_DISCLAIMER = <<~TEXT
    THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
    ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
  TEXT
  LGPL_TEXT = <<~TEXT
    This library is free software; you can redistribute it and/or modify it
    under the terms of the GNU Lesser General Public License as published by
    the Free Software Foundation; either version 2.1 of the License, or (at
    your option) any later version.

    This library is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY.  See the GNU Lesser General Public License for more
    details.
  TEXT
  GPL_LINE = "/* Licensed under the GPLv2. */\n"
  GPL_NOTICE = "/* This program is free software; you can redistribute it and/or modify it under the terms of " \
               "the GNU General Public License as published by the Free Software Foundation; version 2 of the License. */\n"

  NOTICES = {
    'LGPL library' => [comment(<<~TEXT), 'LGPL-2.0-or-later'],
      This library is free software; you can redistribute it and/or modify it
      under the terms of the GNU Library General Public License as published by
      the Free Software Foundation; either version 2 of the License, or (at your
      option) any later version.  See the GNU Library General Public License for
      more details.
    TEXT
    'GCC exception' => [comment(<<~TEXT, leader: '# '), Erx::Attribution::UNRECOGNIZED_NOTICE],
      This file is free software; you can redistribute it and/or modify it under
      the terms of the GNU General Public License as published by the Free
      Software Foundation; either version 3, or (at your option) any later version.

      Under Section 7 of GPL version 3, you are granted additional permissions
      described in the GCC Runtime Library Exception, version 3.1, as published by
      the Free Software Foundation.

      You should have received a copy of the GNU General Public License and a copy
      of the GCC Runtime Library Exception along with this program; see the files
      COPYING3 and COPYING.RUNTIME respectively.  If not, see
      <http://www.gnu.org/licenses/>.
    TEXT
    'GPL by number' => ["// This file is distributed under the terms of the GNU General Public License 2.\n" \
                        "// Please see the COPYING-GPL-2 file for details.\n", 'GPL-2.0-only'],
    'bare GPLv2' => [GPL_LINE, Erx::Attribution::UNRECOGNIZED_NOTICE],
    'bare GPLv2 or later' => ["/* Licensed under GPLv2 or later. */\n", Erx::Attribution::UNRECOGNIZED_NOTICE],
    'stock GPL' => [GPL_NOTICE, 'GPL-2.0-only'],
    'LGPL in %% comments' => [LGPL_TEXT.lines.map { |line| "%% #{line}" }.join, 'LGPL-2.1-or-later'],
    'LLVM' => ["//===- Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.\n" \
               "// See https://llvm.org/LICENSE.txt for license information.\n", 'Apache-2.0 WITH LLVM-exception'],
    'OpenSSL Apache 2.0' => [comment(<<~TEXT), 'Apache-2.0'],
      Licensed under the Apache License 2.0 (the "License").  You may not use
      this file except in compliance with the License.  You can obtain a copy
      in the file LICENSE in the source distribution or at
      https://www.openssl.org/source/license.html
    TEXT
    'BSD-2-Clause' => [comment(BSD_CONDITIONS + "\n" + BSD_DISCLAIMER), 'BSD-2-Clause'],
    'BSD-3-Clause' => [comment(BSD_CONDITIONS + BSD_ENDORSE + "\n" + BSD_DISCLAIMER), 'BSD-3-Clause'],
    'BSD-3-Clause-Attribution' => [comment(BSD_CONDITIONS + BSD_ENDORSE + <<~TEXT + BSD_DISCLAIMER), 'BSD-3-Clause-Attribution'],
      4. Redistributions of any form whatsoever must retain the following
         acknowledgment: 'This product includes software developed by the
         Example Project'.
    TEXT
    'MIT' => [comment(MIT_TEXT + "\n" + MIT_DISCLAIMER), 'MIT'],
    'MIT by name' => ["/* Copyright 2011 A. Author, licensed under standard MIT license */\n", 'MIT'],
    'MIT by name with more terms' => ["/* Licensed under the MIT License with an added restriction. */\n",
                                      Erx::Attribution::UNRECOGNIZED_NOTICE],
    'LGPL in boxed lines' => [LGPL_TEXT.lines.map { |line| "/* #{line.chomp.ljust(76)} */\n" }.join, 'LGPL-2.1-or-later'],
    'SunPro and ISC' => [comment(<<~TEXT), 'SunPro AND ISC'],
      Developed at SunPro, a Sun Microsystems, Inc. business.
      Permission to use, copy, modify, and distribute this
      software is freely granted, provided that this notice
      is preserved.

      Permission to use, copy, modify, and/or distribute this software for any
      purpose with or without fee is hereby granted, provided that the above
      copyright notice and this permission notice appear in all copies.

      THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
      WITH REGARD TO THIS SOFTWARE.
    TEXT
    'FSFAP' => ["# Copying and distribution of this file, with or without modification, are\n" \
                "# permitted in any medium without royalty provided the copyright notice and\n" \
                "# this notice are preserved.  This file is offered as-is, without any warranty.\n", 'FSFAP'],
    'pointer to LICENSE.spdx' => ["/*\n * License: see LICENSE.spdx\n */\n", 'MIT'],
    'MIT with an added condition' => [comment(MIT_TEXT + "\nThe Software shall be used for Good, not Evil.\n\n" +
                                              MIT_DISCLAIMER), Erx::Attribution::UNRECOGNIZED_NOTICE],
    'MIT with the X11 clause' => [comment(MIT_TEXT + "\n" + MIT_DISCLAIMER + <<~TEXT), Erx::Attribution::UNRECOGNIZED_NOTICE],
      Except as contained in this notice, the name of the author shall not be
      used in advertising or otherwise to promote the sale of this Software.
    TEXT
    'BSD with an added condition' => [comment(BSD_CONDITIONS + <<~TEXT + BSD_DISCLAIMER), Erx::Attribution::UNRECOGNIZED_NOTICE],
      3. Redistributions in any form must be accompanied by information on how
         to obtain complete source code for the software.
    TEXT
    'BSD with an unknown acknowledgment' => [comment(BSD_CONDITIONS + <<~TEXT + BSD_DISCLAIMER),
      3. Redistributions must retain the following acknowledgment: Example.
    TEXT
                                             Erx::Attribution::UNRECOGNIZED_NOTICE],
    'GPL with a special exception' => [comment(<<~TEXT), Erx::Attribution::UNRECOGNIZED_NOTICE],
      Distributed under the terms of the GNU General Public License version 2.
      As a special exception, you may link this file with other code.
    TEXT
    'two GNU licenses in one grant' => ["/* GNU Lesser General Public License version 2.1 or the GNU General Public License */\n",
                                        Erx::Attribution::UNRECOGNIZED_NOTICE],
    'public domain' => ["/* This code is in the public domain. */\n", Erx::Attribution::UNRECOGNIZED_NOTICE],
    'lowercase gpl' => ["/* This file is released under the gpl v2. */\n", Erx::Attribution::UNRECOGNIZED_NOTICE],
    'proprietary' => ["/* Confidential and proprietary. Do not distribute. */\n", Erx::Attribution::UNRECOGNIZED_NOTICE],
    'BSD with a condition in its holder' => [comment(BSD_CONDITIONS + "\n" + BSD_DISCLAIMER.sub('THE AUTHOR',
                                                     'THE AUTHOR, FOR NON-COMMERCIAL USE ONLY,')),
                                             Erx::Attribution::UNRECOGNIZED_NOTICE],
    'license by reference' => ["/* Distributed under the terms of the license in COPYING. */\n",
                               Erx::Attribution::UNRECOGNIZED_NOTICE],
    'British spelling' => ["/* Licensed under the Example Public Licence, version 1. */\n",
                           Erx::Attribution::UNRECOGNIZED_NOTICE],
    'a second notice past 16 KiB' => [comment(MIT_TEXT + "\n" + MIT_DISCLAIMER) + ("int x;\n" * 4096) +
                                      "/* Also under the Mozilla Public License 2.0. */\n",
                                      Erx::Attribution::UNRECOGNIZED_NOTICE],
    'UTF-16 text' => ["\xFF\xFE".b + GPL_LINE.encode('UTF-16LE').b, Erx::Attribution::UNRECOGNIZED_NOTICE],
    'binary without a license word' => ["\x7FELF\0\0\0code".b, 'MIT']
  }.freeze

  # The probes whose notices the probe table lists, the pointer as POINTER.
  LISTED = ['LLVM', 'OpenSSL Apache 2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'BSD-3-Clause-Attribution', 'MIT',
            'MIT by name', 'SunPro and ISC', 'FSFAP'].freeze
  PROBE_TABLE = table_of(LISTED.to_h { |name| NOTICES.fetch(name) }
                               .merge(NOTICES.fetch('pointer to LICENSE.spdx').first => 'POINTER')).freeze

  def test_a_files_own_notice_precedes_the_default_and_an_unknown_one_is_unknown
    NOTICES.each do |name, (bytes, license)|
      assert_equal license, attribution('upstream.c', bytes: bytes, notices: PROBE_TABLE).fetch('license'), name
    end
  end

  # A notice's lines are one block however they are laid out, so a sentence
  # added in a paragraph of its own, or a line comment beside the others,
  # changes the block and leaves the file unrecognised.
  def test_a_sentence_beside_a_listed_notice_is_read_with_it
    forms = {
      'boxed lines' => ->(text) { text.lines.map { |line| "/* #{line.chomp.ljust(76)} */\n" }.join },
      'hash lines with blank lines' => ->(text) { text.lines.map { |line| line.strip.empty? ? "\n" : "# #{line}" }.join },
      'a bare comment with blank lines' => ->(text) { "/*\n#{text}*/\n" },
      'plain text with blank lines' => ->(text) { text }
    }
    forms.each do |form, render|
      listed = render.call(MIT_TEXT + "\n" + MIT_DISCLAIMER)
      table = self.class.table_of(listed + "int x;\n" => 'MIT')
      assert_equal 'MIT', attribution('upstream.c', bytes: listed + "int x;\n", notices: table).fetch('license'), form
      added = render.call(MIT_TEXT + "\nThe Software shall be used for Good, not Evil.\n\n" + MIT_DISCLAIMER)
      assert_equal Erx::Attribution::UNRECOGNIZED_NOTICE,
                   attribution('upstream.c', bytes: added + "int x;\n", notices: table).fetch('license'), form
    end
  end

  # The seeded fault on the reviewed table: a file whose notice it lists,
  # with one sentence appended to that notice, is unrecognised.
  def test_a_reviewed_notice_with_a_sentence_more_is_unrecognized
    bytes = File.binread(File.expand_path('../../fiasco/l4re-core/libc/musl/contrib/musl/src/math/__cos.c', __dir__))
    assert_equal 'SunPro', attribution('upstream.c', bytes: bytes).fetch('license')
    seeded = bytes.sub(" * is preserved.\n", " * is preserved.  Not for use in aircraft.\n")
    refute_equal bytes, seeded
    assert_equal Erx::Attribution::UNRECOGNIZED_NOTICE, attribution('upstream.c', bytes: seeded).fetch('license')
  end

  # A listed license holding OR stays one operand beside the file's other
  # notices, so the OR never reaches across them.
  def test_a_dual_license_row_is_one_operand
    dual = self.class.comment(MIT_TEXT + "\n" + MIT_DISCLAIMER)
    table = self.class.table_of(dual => 'MIT OR GPL-2.0-only')
    bytes = dual + "int x;\n" + GPL_NOTICE
    assert_equal '(MIT OR GPL-2.0-only) AND GPL-2.0-only', attribution('upstream.c', bytes: bytes, notices: table).fetch('license')
  end

  # A GNU notice is read only in its stock wordings: a grant or a
  # boilerplate sentence with words added, a negated "any later version" or
  # an exception leaves the file unrecognised.
  def test_a_gnu_notice_is_read_only_in_its_stock_wordings
    free = 'This program is free software; you can redistribute it and/or modify it under the terms of the ' \
           'GNU General Public License as published by the Free Software Foundation;'
    {
      "/* #{free} either version 2 of the License, or (at your option) any later version. */\n" => 'GPL-2.0-or-later',
      "/* #{free} version 2 of the License. See the GNU General Public License for more details. */\n" => 'GPL-2.0-only',
      "/* #{free} version 2, but you may not sell it. */\n" => UNRECOGNIZED,
      "/* #{free} version 3. You should have received a copy of the GNU General Public License, " \
      "but this file is proprietary and confidential. */\n" => UNRECOGNIZED,
      "/* #{free} version 2. You should have received a copy of the GNU General Public License along with " \
      "this program; if not, write to the Free Software Foundation, Inc., but you may not sell it. */\n" => UNRECOGNIZED,
      "/* This file is distributed under version 2 of the GNU General Public License, and not any later version. */\n" =>
        UNRECOGNIZED,
      "/* Licensed under the GPLv2 and is proprietary otherwise. */\n" => UNRECOGNIZED
    }.each do |bytes, license|
      assert_equal license, attribution('upstream.c', bytes: bytes).fetch('license'), bytes
    end
  end

  UNRECOGNIZED = Erx::Attribution::UNRECOGNIZED_NOTICE
  LISTED_MIT = comment(MIT_TEXT + "\n" + MIT_DISCLAIMER)

  # Every comment block of the header, and every comment block beside a
  # notice, is a listed notice, a stock GNU notice or free of legal words,
  # so a restriction written without a license word is still read.
  def test_a_block_in_the_header_or_beside_a_notice_is_read
    table = self.class.table_of(LISTED_MIT => 'MIT')
    described = "/*\n * Copyright (c) 2001 A. Author. All rights reserved.\n * The scheduler's run queues.\n */\n" \
                "#include <stdint.h>\n\n#{LISTED_MIT}\nint x;\n/* sell nothing here */\n"
    {
      described => 'MIT',
      "#{LISTED_MIT}/* You may not redistribute or sell this file. */\nint x;\n" => UNRECOGNIZED,
      "/* Not for redistribution. */\n\n#include <stdint.h>\n#{LISTED_MIT}\nint x;\n" => UNRECOGNIZED,
      "int x;\n#{LISTED_MIT}// Do not sell.\nint y;\n" => UNRECOGNIZED,
      "// #{MIT_TEXT.lines.first}#define X 1\n// Not for redistribution or sale\n" => UNRECOGNIZED
    }.each do |bytes, license|
      assert_equal license, attribution('upstream.c', bytes: bytes, notices: table).fetch('license'), bytes
    end
  end

  # A file may hold one SPDX declaration, on its own line in its header,
  # and it must name every license the file's notices grant.
  def test_one_spdx_declaration_in_the_header_names_every_notice
    table = self.class.table_of(LISTED_MIT => 'MIT')
    {
      "// SPDX-License-Identifier: MIT\n#{LISTED_MIT}int x;\n" => 'MIT',
      "// SPDX-License-Identifier: GPL-2.0-only OR MIT\n#{GPL_NOTICE}int x;\n" => 'GPL-2.0-only OR MIT',
      "// SPDX-License-Identifier: MIT\n#{GPL_NOTICE}int x;\n" => UNRECOGNIZED,
      "#{GPL_NOTICE}print <<X\nSPDX-License-Identifier: MIT\nX\n" => UNRECOGNIZED,
      "// SPDX-License-Identifier: MIT\n// SPDX-License-Identifier: ISC\nint x;\n" => UNRECOGNIZED,
      "// SPDX-License-Identifier: MIT\nconst char *s = \"SPDX-License-Identifier\";\n" => UNRECOGNIZED,
      "/* SPDX-License-Identifier: MIT */\nint x;\n" => 'MIT',
      # Text after a declaration's comment closer is a block the reader
      # never sees, so the line is no declaration and the file is refused.
      "/* SPDX-License-Identifier: MIT */ /* Proprietary; GPL-3.0-only applies. */\nint x;\n" => UNRECOGNIZED,
      "/* SPDX-License-Identifier: MIT */ int x;\n" => UNRECOGNIZED,
      # A declaration that is no license expression refuses the file, not
      # the whole inventory.
      "/* SPDX-License-Identifier: MIT (see LICENSE) */\nint x;\n" => UNRECOGNIZED,
      "# SPDX-License-Identifier: MIT #\nx = 1\n" => UNRECOGNIZED
    }.each do |bytes, license|
      assert_equal license, attribution('upstream.c', bytes: bytes, notices: table).fetch('license'), bytes
    end
  end

  # A listed license is kept in canonical spacing and bracketed when it is
  # joined to another, however its row spaces it.
  def test_a_compound_listed_license_is_bracketed
    row = "#{Digest::SHA256.hexdigest(Erx::Attribution.notice_blocks(LISTED_MIT).first.text)} fixture/a.c MIT OR(Apache-2.0)\n"
    table = Erx::Attribution.send(:notice_table, row)
    assert_equal '(MIT OR (Apache-2.0)) AND GPL-2.0-only',
                 attribution('upstream.c', bytes: "#{LISTED_MIT}int x;\n#{GPL_NOTICE}", notices: table).fetch('license')
  end

  # A reviewed rule judges the bytes it pins; other bytes at its path are
  # unrecognised, and a rule without pinned files is refused at load.
  def test_a_reviewed_rule_judges_only_its_pinned_bytes
    assert_equal 'BSD-2-Clause', attribution('special.c', bytes: GPL_LINE).fetch('license')
    assert_equal UNRECOGNIZED, attribution('special.c', bytes: GPL_LINE + "/* no sale */\n").fetch('license')
  end

  # A profile is refused whole when it is read, before any file's own
  # declaration could make a bad rule unreachable.
  def test_a_review_profile_is_refused_whole_at_load
    [{ 'pattern' => '*', 'license' => 'MIT', 'evidence' => 'a tree' },
     { 'files' => { 'a.c' => 'x' }, 'license' => 'MIT', 'evidence' => 'no hash' },
     { 'pattern' => 'a.c', 'license' => 'MIT', 'kind' => 'guess', 'evidence' => 'none' },
     { 'pattern' => 'a/**/*', 'license' => 'NOASSERTION', 'kind' => 'package', 'evidence' => 'none' }].each do |rule|
      @review['rules'] = [rule]
      assert_raises(Erx::Error, rule.inspect) { attribution('a.c', bytes: "// SPDX-License-Identifier: MIT\n") }
    end
  end

  # A pointer to a package declaration counts only in the import it was
  # reviewed in.
  def test_a_pointer_counts_only_in_its_own_import
    pointer = "/* License: see LICENSE */\n"
    table = self.class.table_of({ pointer => 'POINTER' })
    assert_equal 'MIT', attribution('upstream.c', bytes: pointer, notices: table).fetch('license')
    @review['import'] = 'other'
    assert_equal UNRECOGNIZED, attribution('upstream.c', bytes: pointer, notices: table).fetch('license')
  end

  def test_a_malformed_notice_table_is_refused
    row = "#{'a' * 64} a.c MIT\n"
    assert_equal({ 'a' * 64 => Erx::Attribution::Notice.new(license: 'MIT', imports: []) },
                 Erx::Attribution.send(:notice_table, "# header\n#{row}"))
    ["#{'a' * 63} a.c MIT\n", "#{'A' * 64} a.c MIT\n", "#{'a' * 64} a.c MIT \n", row + row, "#{'b' * 64} b.c MIT\n#{row}", "#{'a' * 64} a.c NOASSERTION\n"].each do |table|
      assert_raises(Erx::Error) { Erx::Attribution.send(:notice_table, table) }
    end
  end

  def test_a_reviewed_rule_precedes_a_notice_and_a_package_rule_follows_it
    @review.fetch('rules') << { 'pattern' => 'package/**/*', 'license' => 'LGPL-2.1-or-later', 'kind' => 'package',
                                'evidence' => 'package declaration' }
    assert_equal 'BSD-2-Clause', attribution('special.c', bytes: GPL_LINE).fetch('license')
    assert_equal 'GPL-2.0-only', attribution('package/a.c', bytes: GPL_NOTICE).fetch('license')
    assert_equal 'LGPL-2.1-or-later', attribution('package/b.c', bytes: "int b;\n").fetch('license')
    @review.fetch('rules') << { 'pattern' => 'x', 'license' => 'MIT', 'kind' => 'guess', 'evidence' => 'none' }
    assert_raises(Erx::Error) { attribution('package/b.c', bytes: "int b;\n") }
    @review.fetch('rules').pop
    @review.fetch('rules') << { 'pattern' => 'lib/**/*', 'license' => 'MIT', 'evidence' => 'a tree' }
    assert_raises(Erx::Error) { attribution('lib/a.c', bytes: GPL_LINE) }
  end

  def test_unknown_permission_is_refused
    assert_equal UNRECOGNIZED,
                 attribution('fixture', bytes: "# SPDX-License-Identifier: NOASSERTION\n").fetch('license')
  end

  def test_complete_license_expression_is_required
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
    assert_match(/lack their erXos change notice: copy\.c/, error.message)
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

  # An imported file erXos deleted is listed under removed with its reason: the
  # check accepts its absence, and refuses it if it comes back.
  def test_a_removed_file_is_accepted_absent_and_refused_present
    write_file('source.c', "/* upstream */\nint value;\n")
    write_file('gone.c', "/* upstream */\nint gone;\n")
    write_origin
    File.unlink(File.join(@directory, 'gone.c'))
    replace_inventory do |payload|
      payload.merge('removed' => [{ 'path' => 'gone.c', 'reason' => 'the generated header replaces it' }])
    end
    assert @origin.check
    write_file('gone.c', "/* upstream */\nint gone;\n")
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/recorded as removed is present: gone\.c/, error.message)
  end

  # An inventory without a field the format requires is refused with the
  # record and the field named, so the tree that needs mending is plain.
  def test_a_missing_inventory_field_names_the_record_and_the_field
    write_file('source.c', "/* upstream */\nint value;\n")
    write_origin
    replace_inventory { |payload| payload.except('removed') }
    error = assert_raises(Erx::Error) { @origin.check }
    assert_includes error.message, File.join(@directory, 'ORIGIN.md')
    assert_includes error.message, 'lacks fields: removed'
  end

  # An unknown field is counted, not echoed, and a mistyped one is named.
  def test_an_unknown_or_mistyped_inventory_field_is_refused
    write_file('source.c', "/* upstream */\nint value;\n")
    write_origin
    replace_inventory { |payload| payload.merge("\e]0;x\a" => 1) }
    error = assert_raises(Erx::Error) { @origin.inventory }
    assert_includes error.message, 'has 1 unknown field(s)'
    refute_includes error.message, "\e"
    replace_inventory { |payload| payload.except("\e]0;x\a").merge('removed' => {}) }
    error = assert_raises(Erx::Error) { @origin.inventory }
    assert_includes error.message, 'field removed is not of class Array'
  end

  # A refusal raised by check itself, outside the inventory reader, names the
  # record too.
  def test_a_tree_refusal_names_the_record
    write_file('source.c', "/* upstream */\nint value;\n")
    write_origin
    File.unlink(File.join(@directory, 'source.c'))
    error = assert_raises(Erx::Error) { @origin.check }
    assert_equal "#{File.join(@directory, 'ORIGIN.md')}: imported source file is missing: source.c", error.message
  end

  # Seeded fault: a removal must name an imported file, so it cannot stand in
  # for an exclusion or hide a file the inventory never listed.
  def test_a_removal_must_name_an_imported_file
    write_file('source.c', "/* upstream */\nint value;\n")
    write_origin
    replace_inventory do |payload|
      payload.merge('removed' => [{ 'path' => 'other.c', 'reason' => 'never imported' }])
    end
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/removal names no imported file: other\.c/, error.message)
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

  # A replaced source (fiasco/kernel's kobject_rpc.h) is held to its changes
  # row's bytes: editing it after the row was written is refused, notice or
  # not, so the row's license never describes bytes it was not written for.
  def test_a_replaced_source_must_keep_its_changes_rows_bytes
    write_file('source.c', "int upstream;\n")
    write_origin
    replacement = "/* Modified by erXos: a replacement */\nint replaced;\n"
    write_file('source.c', replacement)
    replace_inventory do |payload|
      payload.fetch('changes')['source.c'] = {
        'sha256' => Digest::SHA256.hexdigest(replacement), 'license' => 'MIT',
        'evidence' => 'replacement fixture'
      }
      payload
    end
    assert @origin.check
    write_file('source.c', replacement + "int edited;\n")
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/differs from its changes row.*: source\.c/, error.message)
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

  # One check names every changed file without its notice, not only the
  # first.
  def test_every_changed_file_without_its_notice_is_named_at_once
    %w[first.c second.c kept.c].each { |path| write_file(path, "int value;\n") }
    write_origin
    %w[first.c second.c].each { |path| write_file(path, "int changed;\n") }
    write_file('kept.c', "/* Modified by erXos */\nint changed;\n")
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/first\.c/, error.message)
    assert_match(/second\.c/, error.message)
    refute_match(/kept\.c/, error.message)
  end

  # A block comment that closes on its own line, as an imported license header
  # does, leaves nothing of that line to read: the check answers, not crashes.
  def test_a_header_comment_closed_on_its_own_line_is_read
    write_file('source.c', "int value;\n")
    write_origin
    write_file('source.c', "/*\n * License.\n */\nint changed;\n")
    error = assert_raises(Erx::Error) { @origin.check }
    assert_match(/lack their erXos change notice/, error.message)
    write_file('source.c', "/*\n * License.\n */\n// Modified by erXos\nint changed;\n")
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
  # project's license and no other, in any form a reader could take for one.
  def test_new_source_may_declare_only_the_project_license
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
  # license requires its holder's notice kept: another holder's name, or none,
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
                  exclusions: [{ 'path' => 'removed.c', 'reason' => 'license' }, { 'path' => 'gone', 'reason' => 'license' }])
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

  ERXOS_HEADER = "%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n%% SPDX-License-Identifier: BSD-2-Clause\n"

  def own(bytes) = Erx::Attribution.for_own_file(bytes: bytes)

  # An erXos file is attributed by its SPDX line: its prose discusses the
  # Erlang distribution, licenses and copyright as subjects, and a ported
  # file carries the notice its line names.
  def test_own_file_takes_its_declaration_over_its_prose
    prose = "#{ERXOS_HEADER}%% The distribution carrier; the license of each input is checked.\n-module(m).\n"
    assert_equal({ 'license' => 'BSD-2-Clause', 'evidence' => 'file SPDX', 'reviewed' => false }, own(prose))
    ported = "%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
             "%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause\n%%\n%% FreeBSD: sys/netinet/if_ether.c\n" \
             "#{BSD_DISCLAIMER.gsub(/^/, '%% ')}-module(m).\n"
    assert_equal 'BSD-2-Clause AND BSD-3-Clause', own(ported).fetch('license')
  end

  # What an erXos file's declaration cannot understate: a stock GNU notice
  # it does not name, or a second declaration; and a file with neither a
  # declaration nor a notice is unresolved.
  def test_own_file_cannot_understate_its_license
    assert_equal Erx::Attribution::UNRECOGNIZED_NOTICE, own("#{ERXOS_HEADER}-module(m).\n#{GPL_NOTICE}").fetch('license')
    assert_equal Erx::Attribution::UNRECOGNIZED_NOTICE,
                 own("#{ERXOS_HEADER}-module(m).\n%% SPDX-License-Identifier: MIT\n").fetch('license')
    assert_equal 'GPL-2.0-only', own("-module(m).\n#{GPL_NOTICE}").fetch('license')
    ['Taken from a GPLed driver.', 'Parts are under the EUPL-1.2.', 'See the GNU Free Documentation License.'].each do |line|
      assert_equal Erx::Attribution::UNRECOGNIZED_NOTICE, own("#{ERXOS_HEADER}%% #{line}\n-module(m).\n").fetch('license'), line
    end
    assert_equal 'BSD-2-Clause', own("#{ERXOS_HEADER}%% GPLEV0 holds the pin levels.\n-module(m).\n").fetch('license')
    mixed = GPL_NOTICE.sub(' */', ' Parts are under the MPL 2.0. */')
    assert_equal Erx::Attribution::UNRECOGNIZED_NOTICE,
                 own("/* SPDX-License-Identifier: GPL-2.0-only */\n-module(m).\n#{mixed}").fetch('license')
    assert_equal 'NOASSERTION', own("%% The distribution carrier.\n-module(m).\n").fetch('license')
  end
end
