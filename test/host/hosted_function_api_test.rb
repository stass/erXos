# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/function_api'

# erx-gate: sanitizers

# The function-API set on liberx's hosted backend (docs/design-stopgap.md, "The call
# table", "The hosted backend"), with and without each sanitizer: every line of the
# transcript in order and a clean exit. The same source runs on native Fiasco through
# tools/lib/erx/qemu_suites/function_api.rb. Each seed must make a case fail, so a green
# run says the set reaches the backend: liberx/backend/hosted/vm.c,
# liberx/backend/hosted/thread.c, liberx/backend/hosted/wait.c,
# liberx/backend/hosted/group.c, liberx/backend/core/vm_table.c and
# liberx/backend/core/park_table.c are its cores.
class HostedFunctionApiTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = Erx::FunctionApi::HOSTED_SOURCES
  FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O1 -g -pthread
             -I include -I kernel/generated -I kernel/core -I kernel/crypto -I .].freeze
  STRICT_ASAN = 'detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:' \
                'allocator_may_return_null=1:halt_on_error=1'
  SANITIZERS = {
    'address' => { flags: %w[-fsanitize=address -fno-omit-frame-pointer], env: { 'ASAN_OPTIONS' => STRICT_ASAN } },
    'undefined' => { flags: %w[-fsanitize=undefined -fno-sanitize-recover=all -fno-omit-frame-pointer], env: {} },
    'thread' => { flags: %w[-fsanitize=thread -fno-omit-frame-pointer], env: { 'TSAN_OPTIONS' => 'halt_on_error=1' } }
  }.freeze

  # name => [file, original, replacement, the case that must notice].
  SEEDS = {
    'used reported as exact' => ['liberx/backend/core/object_info.c', "\t\treport.budget.used = facts->budget_used;\n",
                                "\t\treport.budget.used = facts->budget_used;\n\t\treport.budget.reported = ERX_INFO_BUDGET_REPORTED_USED;\n", 'object_info'],
    'no machine bit' => ['liberx/backend/core/object_info.c', 'facts->cpus_online != 0 ? ERX_INFO_MACHINE_REPORTED_CPUS_ONLINE : 0', '0', 'object_info'],
    'a listing never ends' => ['liberx/backend/core/object_info.c', "\t\tif (!nth_thread(facts->threads, index, &id))\n\t\t\treturn (ERX_ERANGE);\n", "\t\tid = 0;\n\t\t(void)nth_thread;\n", 'object_info'],
    'a decommitted page keeps its bytes' => ['liberx/backend/hosted/vm.c', "\tif ((*byte & PAGE_DIRTY) != 0)\n\t\tpage_clean(addr);\n", '', 'decommit_recommit_reads_zeros'],
    'a thread starts twice' => ['liberx/backend/hosted/thread.c', 'self->state == THREAD_CREATED', 'true', 'double_start_refused'],
    'the thread stays on the host stack' => ['liberx/backend/hosted/thread.c', "\terx_hosted_switch_stack(self->start.regs.sp, thread_run, self, &self->host_sp);\n", "\tthread_run(self);\n", 'tls_and_arg'],
    'a wake reports nobody' => ['liberx/backend/hosted/wait.c', "\t\twoken++;\n", "\t\tbreak;\n", 'umtx_wake_counts'],
    'a worker may park' => ['liberx/backend/hosted/group.c', "\tif (slot == ERX_NO_EXECUTOR_SLOT)\n\t\treturn (ERX_ETYPE);\n\treturn (erx_backend_park_wait", "\treturn (erx_backend_park_wait", 'park_refusals'],
    'a line is created' => ['liberx/backend/hosted/group.c', 'if (kind == ERX_IRQ_LINE || kind == ERX_IRQ_MSI)', 'if (kind == ERX_IRQ_MSI)', 'irq_line_refused'],
    'an MSI is created' => ['liberx/backend/hosted/group.c', 'if (kind == ERX_IRQ_LINE || kind == ERX_IRQ_MSI)', 'if (kind == ERX_IRQ_LINE)', 'irq_refusals']
  }.freeze

  def setup
    skip 'the hosted backend needs a macOS host' unless RUBY_PLATFORM.include?('darwin')
    @directory = Dir.mktmpdir('hosted-function-api')
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(name, flags: [], replaced: {})
    output = File.join(@directory, name.tr(' ', '-'))
    sources = SOURCES.map { |source| replaced.fetch(source) { File.join(ROOT, source) } }
    log, status = Open3.capture2e(compiler, *FLAGS, *flags, *sources, '-o', output, chdir: ROOT, stdin_data: '')
    assert status.success?, log
    output
  end

  def run_set(binary, env: {}) = Open3.capture2e(env, binary, stdin_data: '')

  def assert_clean(log, status)
    assert status.success?, log
    assert_equal Erx::FunctionApi.hosted_lines, log.lines.map(&:chomp), log
  end

  def test_the_set_passes_without_a_sanitizer
    log, status = run_set(build('plain'))
    assert_clean(log, status)
  end

  SANITIZERS.each do |name, sanitizer|
    define_method("test_the_set_passes_under_#{name}") do
      log, status = run_set(build(name, flags: sanitizer.fetch(:flags)), env: sanitizer.fetch(:env))
      assert_clean(log, status)
    end
  end

  SEEDS.each do |name, (file, original, replacement, broken)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, file))
      assert_includes source, original, 'the seed no longer applies'
      seeded = File.join(@directory, File.basename(file))
      File.write(seeded, source.sub(original) { replacement })
      binary = build("seed-#{name}", flags: ['-Wno-unused-function', '-Wno-unused-parameter'], replaced: { file => seeded })
      log, = run_set(binary)
      refute_includes log.lines.map(&:chomp), "erx: function-api: #{broken} ok", log
    end
  end

  # Nothing in the set may depend on what only one backend gives.
  def test_the_set_reads_no_backend_identifier
    %w[cases.c cases.h irq_cases.c].each do |name|
      text = File.read(File.join(ROOT, 'test/guest/function_api', name))
      refute_match(/fiasco|\bl4_|sigma0|os_sync|pthread/i, text.gsub(%r{/\*.*?\*/}m, ''), name)
    end
  end
end
