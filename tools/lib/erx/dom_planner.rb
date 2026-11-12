# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'pack_tools'

module Erx
  # The manifest check's run of the domain library's planner (docs/design-system.md,
  # "The manifest", property 12): the host build of the library (tools/host/dom_plan.c)
  # builds the boot's view from the packed manifest with the root's own builder
  # (liberx/system/dom_boot_view.c), then plans each configured domain in boot order,
  # each introduction and each enabled start row's session (property 17) against it,
  # recording every plan it makes. This boundary writes the manifest, each archive
  # entry's head and the plan file the helper's header comment describes, and reads back
  # one status per domain, per introduction and per session.
  class DomainPlanner
    def initialize(helper:, runner:)
      unless helper.is_a?(PackTools::Helper) && helper.tool == 'domains'
        raise Error, 'domain planning requires a helper owned by PackTools.build'
      end

      @helper = helper
      @runner = runner
    end

    # view: 'manifest' (the packed manifest's bytes), 'files' (each archive entry's
    # kind, flags and head, the bytes the archive holds at its start), 'order' (the
    # configured rows in boot order), 'introductions' (a and b, each a place in
    # 'order') and 'sessions' (the session template of each enabled start row). Returns
    # 'domains', 'introductions' and 'sessions', each entry's erx_status_t in its list's
    # order, 0 for one the library plans, or 'refused' alone, the library's reason, when
    # it refuses the view itself.
    def call(view)
      Dir.mktmpdir('erx-dom-plan-') do |directory|
        paths = %w[manifest.bin heads.bin plan.txt].map { |name| File.join(directory, name) }
        File.binwrite(paths[0], view.fetch('manifest'))
        File.binwrite(paths[1], view.fetch('files').map { |row| row.fetch('head').b }.join)
        File.binwrite(paths[2], self.class.input(view))
        record = @helper.run(paths, runner: @runner, name: 'dom-plan', deadline: 60)
        self.class.statuses(File.binread(record.fetch('log')), domains: view.fetch('order').size,
                                                                introductions: view.fetch('introductions').size,
                                                                sessions: view.fetch('sessions').size)
      end
    end

    def self.input(view)
      lines = view.fetch('files').map { |row| ['file', *row.values_at('kind', 'flags'), row.fetch('head').bytesize] }
      lines.concat(view.fetch('order').map { |row| ['order', row] })
      lines.concat(view.fetch('introductions').map { |row| ['introduce', *row.values_at('a', 'b')] })
      lines.concat(view.fetch('sessions').map { |template| ['session', template] })
      lines.map { |words| "#{words.join(' ')}\n" }.join
    end

    # The helper's reply: `refused REASON` alone, or `domain N STATUS` for each domain
    # in order, then `introduce N STATUS` for each introduction, then `session N STATUS`
    # for each session, and nothing else.
    def self.statuses(bytes, domains:, introductions:, sessions:)
      lines = bytes.b.lines
      if lines.size == 1 && (refusal = lines.first.match(/\Arefused ([ -~]+)\n\z/))
        return { 'refused' => refusal[1] }
      end

      counts = { 'domain' => domains, 'introduce' => introductions, 'session' => sessions }
      expected = counts.flat_map { |kind, count| Array.new(count) { |index| [kind, index] } }
      unless lines.size == expected.size &&
             lines.zip(expected).all? { |line, (kind, index)| line.match?(/\A#{kind} #{index} -?[0-9]+\n\z/) }
        raise Error, 'domain planner reply is not one status per domain, introduction and session'
      end

      statuses = lines.map { |line| Integer(line.split.last, 10) }
      { 'domains' => statuses.first(domains), 'introductions' => statuses.drop(domains).first(introductions),
        'sessions' => statuses.drop(domains + introductions) }
    end
  end
end
