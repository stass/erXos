# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'etc'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/function_api'
require_relative '../../tools/lib/erx/runtime'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The function-API set on liberx's hosted backend (docs/design-stopgap.md, "The call
# table", "The hosted backend"), with and without each sanitizer: every line of the
# transcript in order and a clean exit. The same source runs on native Fiasco through
# tools/lib/erx/qemu_suites/function_api.rb. Each seed must make a case fail, so a green
# run says the set reaches the backend: liberx/backend/hosted/vm.c,
# liberx/backend/hosted/thread.c, liberx/backend/hosted/wait.c,
# liberx/backend/hosted/group.c, liberx/backend/core/vm_table.c,
# liberx/backend/core/park_table.c and liberx/backend/core/entropy_take.c are its cores.
class HostedFunctionApiTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = Erx::FunctionApi::HOSTED_SOURCES
  FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O1 -g -pthread
             -I build/gen -I build/gen/include -I include -I build/gen/kernel/generated -I kernel/core -I kernel/crypto -I .].freeze
  # The policy's options plus the initialization-order checks, which the
  # policy runs only off macOS.
  STRICT_ASAN = %w[check_initialization_order=1 strict_init_order=1].freeze
  SANITIZERS = {
    'address' => { flags: %w[-fsanitize=address -fno-omit-frame-pointer], options: { asan: STRICT_ASAN } },
    'undefined' => { flags: %w[-fsanitize=undefined -fno-sanitize-recover=all -fno-omit-frame-pointer], options: {} },
    'thread' => { flags: %w[-fsanitize=thread -fno-omit-frame-pointer], options: {} }
  }.freeze

  # name => [file, original, replacement, the case that must notice].
  SEEDS = {
    'used reported as exact' => ['liberx/backend/core/object_info.c', "\t\treport.budget.used = facts->budget_used;\n",
                                "\t\treport.budget.used = facts->budget_used;\n\t\treport.budget.reported = ERX_INFO_BUDGET_REPORTED_USED;\n", 'object_info'],
    'no machine bit' => ['liberx/backend/core/object_info.c', 'facts->cpus_online != 0 ? ERX_INFO_MACHINE_REPORTED_CPUS_ONLINE : 0', '0', 'object_info'],
    'memory reported as exact' => ['liberx/backend/core/object_info.c', '(facts->uptime_ns != 0 ? ERX_INFO_MACHINE_REPORTED_UPTIME : 0);',
                                   '(facts->uptime_ns != 0 ? ERX_INFO_MACHINE_REPORTED_UPTIME : 0) | ERX_INFO_MACHINE_REPORTED_MEMORY_FREE;', 'object_info'],
    'a listing never ends' => ['liberx/backend/core/object_info.c', "\t\tif (!nth_thread(facts->threads, index, &id))\n\t\t\treturn (ERX_ERANGE);\n", "\t\tid = 0;\n\t\t(void)nth_thread;\n", 'object_info'],
    'a decommitted page keeps its bytes' => ['liberx/backend/hosted/vm.c', "\tif ((*byte & PAGE_DIRTY) != 0)\n\t\tpage_clean(addr);\n", '', 'decommit_recommit_reads_zeros'],
    'a thread starts twice' => ['liberx/backend/hosted/thread.c', 'self->state == THREAD_CREATED', 'true', 'double_start_refused'],
    'the thread stays on the host stack' => ['liberx/backend/hosted/thread.c', "\terx_hosted_switch_stack(self->start.regs.sp, thread_run, self, &self->host_sp);\n", "\tthread_run(self);\n", 'tls_and_arg'],
    'a wake reports nobody' => ['liberx/backend/hosted/wait.c', "\t\twoken++;\n", "\t\tbreak;\n", 'umtx_wake_counts'],
    'a worker may park' => ['liberx/backend/hosted/group.c', "\tif (slot == ERX_NO_EXECUTOR_SLOT)\n\t\treturn (ERX_ETYPE);\n\treturn (erx_backend_park_wait", "\treturn (erx_backend_park_wait", 'park_refusals'],
    'a line is created' => ['liberx/backend/hosted/group.c', 'if (kind == ERX_IRQ_LINE || kind == ERX_IRQ_MSI)', 'if (kind == ERX_IRQ_MSI)', 'irq_line_refused'],
    'an MSI is created' => ['liberx/backend/hosted/group.c', 'if (kind == ERX_IRQ_LINE || kind == ERX_IRQ_MSI)', 'if (kind == ERX_IRQ_LINE)', 'irq_refusals'],
    'a take leaves its bytes in mr' => ['liberx/backend/core/entropy_take.c', "\t\t\t(void)erx_utcb_mr_store(utcb, at / sizeof(uint64_t), 0);\n", '', 'entropy_take']
  }.freeze

  def setup
    skip Erx::Runtime::HOST_RULE unless Erx::Runtime.host_supported?
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
      env = Erx::SanitizerEnvironment.call(**sanitizer.fetch(:options), compiler: compiler)
      log, status = run_set(build(name, flags: sanitizer.fetch(:flags)), env: env)
      assert_clean(log, status)
    end
  end

  # Seeds whose path runs only when a host page holds several erXos pages (16 KiB on Apple
  # Silicon): there a decommitted page beside a committed one stays mapped and is cleaned.
  HOST_PAGE_SEEDS = ['a decommitted page keeps its bytes'].freeze

  SEEDS.each do |name, (file, original, replacement, broken)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      if HOST_PAGE_SEEDS.include?(name) && Etc.sysconf(Etc::SC_PAGESIZE) <= 4096
        skip "a host page of erXos's own size has no committed sibling, so the seeded path never runs"
      end
      source = File.read(File.join(ROOT, file))
      assert_includes source, original, 'the seed no longer applies'
      seeded = File.join(@directory, File.basename(file))
      File.write(seeded, source.sub(original) { replacement })
      binary = build("seed-#{name}", flags: ['-Wno-unused-function', '-Wno-unused-parameter'], replaced: { file => seeded })
      log, = run_set(binary)
      refute_includes log.lines.map(&:chomp), "erx: function-api: #{broken} ok", log
    end
  end

  # liberx's header offers the generator's bytes only through erx_entropy_take, so a
  # caller that reads the generator itself, leaving its bytes in mr, does not build; the
  # same file with the take does, so the refusal is the missing declaration alone.
  def test_a_caller_outside_the_funnel_cannot_name_the_read
    { 'erx_entropy_take(out, 16)' => true, 'erx_entropy_read(16)' => false }.each do |call, builds|
      source = File.join(@directory, 'caller.c')
      File.write(source, "#include <stdint.h>\n#include \"liberx/backend/api.h\"\n" \
                         "int f(uint8_t out[16]) { (void)out; return #{call}; }\n")
      log, status = Open3.capture2e(compiler, *FLAGS, '-fsyntax-only', source, chdir: ROOT, stdin_data: '')
      assert_equal builds, status.success?, log
      assert_match(/erx_entropy_read/, log) unless builds
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
