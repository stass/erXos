# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'tmpdir'
require_relative '../../tools/lib/erx/function_api'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# erx_pthread_create_executor on the hosted backend (docs/design-runtime.md, "Making an
# executor"), by test/fixtures/hosted_executor_driver.c. Each seed makes a case fail, so
# the driver is known to notice what it checks.
class HostedExecutorTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = Erx::FunctionApi::HOSTED_SOURCES.grep_v(%r{\Atest/guest/}).freeze
  DRIVER = 'test/fixtures/hosted_executor_driver.c'
  THREAD_SOURCE = 'liberx/backend/hosted/thread.c'
  FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O1 -g -pthread
             -I build/gen -I build/gen/include -I include -I build/gen/kernel/generated -I kernel/core -I kernel/crypto -I .].freeze
  CASES = ['the clock is the uptime clock',
           'an executor has a slot and parks to its deadline', 'a plain pthread has no slot and may not park',
           "the creator's attributes are the thread's", 'slots return after a return',
           'slots return after a pthread_exit', 'slots return after erx_thread_exit', 'the group still fills'].freeze
  BUDGET_SECONDS = 60

  # name => [original, replacement, the case that must notice].
  SEEDS = {
    'the call makes a plain thread' => ['pthread_create(thread, attr, executor_main, self)',
                                        'pthread_create(thread, attr, start, arg)',
                                        'an executor has a slot and parks to its deadline'],
    'nothing gives the slot back' => ["\texecutor_give_back(self);\n\tthread_self = NULL;\n", "\t(void)self;\n\tthread_self = NULL;\n",
                                      'slots return after a return']
  }.freeze

  def setup
    skip 'the hosted backend needs a macOS host' unless RUBY_PLATFORM.include?('darwin')
    @directory = Dir.mktmpdir('hosted-executor')
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def build(name, replaced: {}, flags: [])
    output = File.join(@directory, name.tr(' ', '-'))
    sources = (SOURCES + [DRIVER]).map { |source| replaced.fetch(source) { File.join(ROOT, source) } }
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), *FLAGS, *flags, *sources, '-o', output, chdir: ROOT)
    assert status.success?, log
    output
  end

  # A seeded driver can wait forever in its round, so the answer is what it printed by the deadline.
  def run_driver(binary, env: {})
    log = +''
    Open3.popen2e(env, binary, pgroup: true) do |stdin, out, thread|
      stdin.close
      begin
        Timeout.timeout(BUDGET_SECONDS) { out.each_line { |line| log << line } }
        assert thread.value.success?, log
      rescue Timeout::Error
        Process.kill('KILL', -thread.pid)
      end
    end
    log
  end

  def results(log) = log.lines.to_h { |line| line.chomp.split(': ', 2) }

  def test_every_case_passes
    assert_equal CASES.to_h { |name| [name, 'ok'] }, results(run_driver(build('plain')))
  end

  SEEDS.each do |name, (original, replacement, noticed_by)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      text = File.read(File.join(ROOT, THREAD_SOURCE))
      assert_includes text, original
      seeded = File.join(@directory, 'seeded_thread.c')
      File.write(seeded, text.sub(original, replacement))
      assert_equal 'FAILED', results(run_driver(build(name, replaced: { THREAD_SOURCE => seeded }, flags: %w[-Wno-unused-function])))[noticed_by]
    end
  end

  def test_every_case_passes_under_the_thread_sanitizer
    log = run_driver(build('tsan', flags: %w[-fsanitize=thread -fno-omit-frame-pointer]),
                     env: Erx::SanitizerEnvironment.call(compiler: ENV.fetch('ERX_CLANG', 'clang')))
    assert_equal CASES.to_h { |name| [name, 'ok'] }, results(log)
  end
end
