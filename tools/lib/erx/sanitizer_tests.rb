# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bounded_file'
require_relative 'core_archive'
require_relative 'error'
require_relative 'test_pool'

module Erx
  # Which test files `make check-sanitizers` runs. A test joins the gate with
  # one line of its own, `# erx-gate: sanitizers`, so a new test needs no
  # entry in a list. Because this decides what a security gate runs, leaving
  # a test out takes more than forgetting: a comment that resembles the
  # declaration but is not it, a test that reads the sanitizer switch itself
  # or through a helper and does not declare, a kernel core or liberx source
  # that no declaring test names, and a gate with nothing in it are all errors.
  module SanitizerTests
    module_function

    DECLARATION = '# erx-gate: sanitizers'
    # The test pool's `# erx-gate: serial` is the only other declaration.
    KNOWN_DECLARATIONS = [DECLARATION, TestPool::SERIAL_DECLARATION].freeze
    # Any comment trying to be a declaration, spelled however.
    DECLARATION_LIKE = /^\s*#[\W_]*erx[\W_]*gates?\b.*$/i
    DIRECTORIES = %w[test/host test/integration].freeze
    # How a test or a helper reads the switch that builds its C under the
    # sanitizers, in either form and either quote.
    SWITCH_READ = /\bENV\s*(?:\.fetch\s*\(|\[)\s*['"]ERX_SANITIZERS['"]/
    MAX_TEST_BYTES = 4 << 20

    # The relative paths of the tests that declare the gate under root.
    def discover(root:)
      tests = DIRECTORIES.flat_map { |directory| Dir.glob("#{directory}/*_test.rb", base: root) }
      helpers = Dir.glob('test/{fixtures/**/*,host/*}.rb', base: root) - tests
      select(tests.to_h { |path| [path, read(root, path)] },
             switch_helpers: helpers.select { |path| read(root, path).match?(SWITCH_READ) },
             sources: CoreArchive.core_files(root) + Dir.glob('liberx/*.c', base: root))
    end

    # The decision, on the files' text: tests maps each path to its text,
    # switch_helpers lists the helpers that read the switch, and each of
    # sources must be named by a test that declares the gate.
    def select(tests, switch_helpers:, sources:)
      tests.each do |path, text|
        stray = text.scan(DECLARATION_LIKE).map(&:strip).reject { |line| KNOWN_DECLARATIONS.include?(line) }
        raise Error, "sanitizer gate: #{path}: malformed declaration #{stray.first}" unless stray.empty?
      end
      declared = tests.select { |_path, text| text.match?(/^\s*#{Regexp.escape(DECLARATION)}\s*$/) }
      raise Error, 'sanitizer gate: no test declares it' if declared.empty?

      undeclared = tests.reject { |path, _text| declared.key?(path) }
                        .select { |_path, text| reads_switch?(text, switch_helpers) }.keys
      unless undeclared.empty?
        raise Error, "sanitizer gate: #{undeclared.sort.join(', ')} reads the sanitizer switch; add `#{DECLARATION}`"
      end
      untested = sources.reject { |source| declared.values.any? { |text| text.include?(source) } }
      unless untested.empty?
        raise Error, "sanitizer gate: no test with `#{DECLARATION}` names #{untested.sort.join(', ')}"
      end

      declared.keys.sort
    end

    def reads_switch?(text, helpers)
      text.match?(SWITCH_READ) ||
        helpers.any? { |helper| text.match?(%r{['"/]#{Regexp.escape(File.basename(helper, '.rb'))}['"]}) }
    end
    private_class_method :reads_switch?

    def read(root, path) = BoundedFile.read(File.join(root, path), maximum: MAX_TEST_BYTES)
    private_class_method :read
  end
end
