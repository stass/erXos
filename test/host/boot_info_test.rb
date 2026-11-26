# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The boot information page and the command line (docs/design-fiasco.md, "Boot
# information" and "The command line"): liberx/backend/core/boot_info.c and
# kernel/core/boot_args.c at every limit, with the holder records of
# liberx/backend/core/boot_manifest.c, driven by
# test/fixtures/boot_info_driver.c. Each seed below must make the driver name what it broke.
class BootInfoTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  INFO = 'liberx/backend/core/boot_info.c'
  ARGS = 'kernel/core/boot_args.c'
  WATCHDOG = 'kernel/core/watchdog.c'
  MANIFEST = 'liberx/backend/core/boot_manifest.c'
  DRIVER = 'test/fixtures/boot_info_driver.c'

  # name => [source, original, replacement, the driver's diagnostic].
  MUTANTS = {
    'an unchecked args_off' => [INFO, 'span_ok(info->args_off, info->args_len, fixed, size)', 'true', 'bounds'],
    'a strings limit one too wide' => [INFO, 'need > ERX_BOOT_STRINGS_MAX - *total', 'need > ERX_BOOT_STRINGS_MAX + 1 - *total', 'strings limit'],
    'erx.trace overridden by the image form' => [ARGS, 'return (args->have_trace ? args->trace : development);', 'return ((void)args, development);',
                                                'erx.trace=0 leaves'],
    'a word past the limit accepted' => [ARGS, 'length + 1 > ERX_BOOT_STRINGS_MAX - out->arg_bytes', 'false', 'erx.arg limit'],
    'the system node laid over the node' => [INFO, '(uint32_t)(fixed + inputs->node_len) : 0', '(uint32_t)fixed : 0', 'system node'],
    'the node let through as its own peer' => [INFO, 'return (peer_len != node_len || memcmp(peer, node, node_len) != 0);', 'return ((void)node, (void)node_len, (void)peer, true);', 'own peer'],
    'a connection with no peer let through' => [INFO, 'return (all_zero((const uint8_t *)&connection, sizeof(connection)));', 'return (true);', 'no peer'],
    'an empty word let through' => [INFO, 'if (word == 0)', 'if (false)', 'word list'],
    'the process table flag dropped' => [INFO, "\tused = text_append(words, used, \"-P\");\n\tused = decimal_append(words, used, limits->processes);\n", "", 'erts flags'],
    'processes not a power of two let through' => [INFO, 'if (processes == 0 || (processes & (processes - 1)) != 0)', 'if (processes == 0)', 'erts refusal'],
    'online taken from the cpuset' => [INFO, '(capacity_cpus > schedulers ? schedulers : (uint32_t)capacity_cpus)', 'schedulers', 'erts flags: the words'],
    'a raised process table admitted' => [INFO, 'if (settings->processes > limits->processes)', 'if (false)', 'admit'],
    'the given record without its memory size' => [MANIFEST, 'number_put(words, capacity, &used, given->memory_size)', 'true', 'holder'],
    'the system_image record without its tree length' => [MANIFEST, 'number_put(words, capacity, &used, row->tree_length)', 'true', 'system_image'],
    'the system_image length and tree offset swapped' => [MANIFEST, "number_put(words, capacity, &used, row->image_length) &&\n\t    number_put(words, capacity, &used, row->tree_offset)", "number_put(words, capacity, &used, row->tree_offset) &&\n\t    number_put(words, capacity, &used, row->image_length)", 'system_image'],
    'the record_volume word written for a holder without the window' => [MANIFEST, '(!record_volume || word_put(', '((void)record_volume, word_put(', "the record's words"],
    'a system_image salt past its array written' => [MANIFEST, 'row->salt_length == 0 || row->salt_length > sizeof(row->salt)', 'row->salt_length == 0', 'salt past its array'],
    'a second framebuffer record let through' => [INFO, "\t\tif (found)\n\t\t\treturn (false);\n", '', 'second record'],
    'a framebuffer record read before --' => [INFO, "\tdo\n\t\tword = next_word(words, length, &used);\n\twhile (word != NULL && strcmp(word, \"--\") != 0);\n", '', 'emulator flag'],
    'the page marked before the checks' => [INFO, "\tif (status != ERX_BOOT_INFO_OK)\n\t\treturn (status);\n\tif (size < fixed", "\tmemset(page, 0, size);\n\tif (status != ERX_BOOT_INFO_OK)\n\t\treturn (status);\n\tif (size < fixed", 'untouched']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-boot-info-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(sources, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, *sources, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def sources = [INFO, ARGS, WATCHDOG, MANIFEST].map { |source| File.join(ROOT, source) } +
                [Erx::Generated.path('liberx/generated/abi_reader.c', root: ROOT)]

  def test_the_page_and_the_command_line_at_every_limit
    output, status = Open3.capture2e(build(sources, name: 'driver'), stdin_data: '')
    assert status.success?, output
    assert_match(/\Aboot info: ok\n/, output)
  end

  # The words the domain library writes for the system window's holder are the words
  # erx_device_record:system_image/1 reads (docs/design-fiasco.md, "The booted slot"):
  # the driver's record of a three-byte salt with a leading zero byte and the root hash
  # 0 to 31 reads back as that row, under stock's emulator (ERX_ERL and ERX_ERLC).
  def test_the_system_image_record_reads_back_in_erlang
    words, status = Open3.capture2e(build(sources, name: 'driver'), 'system_image', stdin_data: '')
    assert status.success?, words
    record = words.lines(chomp: true).map { |word| %("#{word}") }.join(', ')
    expected = '#{image_offset => 0, image_length => 16773120, tree_offset => 16777216, tree_length => 135168, ' \
               "salt => <<0, 171, 127>>, root_hash => list_to_binary(lists:seq(0, 31))}"
    Dir.mktmpdir('erx-boot-info-record') do |work|
      ErlangBuild.compile(work, applications: %w[erx])
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                       "Expected = #{expected}, Read = erx_device_record:system_image([[#{record}]]), " \
                                       'io:format("~p~n", [Read]), halt(case Read of {ok, Expected} -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
    end
  end

  MUTANTS.each do |name, (source, original, replacement, diagnostic)|
    define_method("test_#{name.tr(' ', '_')}_is_caught") do
      text = File.read(File.join(ROOT, source))
      assert_includes text, original
      seeded = File.join(@directory, "seeded_#{File.basename(source)}")
      File.write(seeded, text.sub(original) { replacement })
      output, status = Open3.capture2e(build(sources.map { |path| path.end_with?(source) ? seeded : path }, name: name), stdin_data: '')
      refute status.success?, "#{name} went unnoticed"
      assert_match(/#{diagnostic}/, output)
    end
  end
end
