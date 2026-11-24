# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'

# Runs an EUnit module against modules of the tree's OTP compiled from source with stock's
# compiler (ERX_ERLC) on stock's emulator (ERX_ERL), -nostick so that they replace its own.
# A tree module takes over from the start, so the emulator's own processes run it (its
# group, whose state a later load would not fit), unless it is named late: one that cannot
# serve the emulator's own terminal, as the tree's prim_tty with no NIF cannot, is loaded
# once the emulator has started. EUnit reports to a file rather than to the terminal, which
# a late prim_tty leaves the emulator's own `user` unable to print to.
module OtpEunit
  ROOT = File.expand_path('../..', __dir__)
  DEADLINE = '300'

  # passed: whether the test module ran and every case passed; output: the compiler's and
  # the emulator's output and EUnit's report, for a failure message.
  Result = Data.define(:passed, :output)

  # Compiles sources, root-relative paths of the tree's OTP modules, those in late into a
  # directory of their own, and test, the root-relative path of the EUnit module, under work,
  # an existing directory, and runs the test module there. replaced maps a root-relative path
  # of sources to the text compiled in its place, a seeded fault.
  def self.run(work, sources:, test:, late: [], replaced: {})
    late_dir = File.join(work, 'late')
    FileUtils.mkdir_p(late_dir)
    compiled = [[sources - late + [test], work], [late, late_dir]].reject { |paths, _| paths.empty? }
    compiled.each do |paths, out|
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERLC'),
                                       *include_flags(sources), '-o', out,
                                       *paths.map { |path| source_path(work, path, replaced) }, stdin_data: '')
      return Result.new(passed: false, output: output) unless status.success?
    end
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-nostick',
                                     '-pa', work, '-eval', eval_text(late, File.basename(test, '.erl')),
                                     chdir: work, stdin_data: '')
    report_path = File.join(work, 'eunit.out')
    report = File.exist?(report_path) ? File.read(report_path) : ''
    Result.new(passed: status.success? && report.match?(/All \d+ tests passed/), output: output + report)
  end

  # Where path is compiled from: the tree's file, or the text replaced gives it, written
  # under work with the same base name, so the module keeps its name.
  def self.source_path(work, path, replaced)
    return File.join(ROOT, path) unless replaced.key?(path)

    dir = File.join(work, 'replaced')
    FileUtils.mkdir_p(dir)
    File.join(dir, File.basename(path)).tap { |copy| File.write(copy, replaced.fetch(path)) }
  end

  # Each source's application's src and include directories, for its -include and
  # -include_lib lines.
  def self.include_flags(sources)
    sources.map { |path| File.dirname(path, 2) }.uniq
           .flat_map { |app| %w[src include].flat_map { |dir| ['-I', File.join(ROOT, app, dir)] } }
  end

  # Each late module is purged and loaded over the emulator's own, and the test module
  # reports to eunit.out.
  def self.eval_text(late, test_module)
    modules = late.map { |path| File.basename(path, '.erl') }.join(', ')
    "[{module, M} = begin code:purge(M), code:load_abs(\"late/\" ++ atom_to_list(M)) end || M <- [#{modules}]], " \
      '{ok, Out} = file:open("eunit.out", [write]), group_leader(Out, self()), ' \
      "halt(case eunit:test(#{test_module}, [verbose]) of ok -> 0; _ -> 1 end)."
  end

  private_class_method :source_path, :include_flags, :eval_text
end
