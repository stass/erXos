# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'pack_tools'

module Erx
  # The manifest check's run of the domain library's planner (docs/design-system.md,
  # "The manifest", property 12): the host build of erx_dom_plan_configured
  # (tools/host/dom_plan.c) plans each configured-domain row against the view of a
  # machine just booted. This boundary writes the view as the helper's text input and
  # reads back one status per row; the input format is the helper's header comment.
  class DomainPlanner
    GRANT_FIELDS = %w[quota_ns period_ns cpuset capacity_mcpu capacity_first slice_us grace_us base ceiling flags].freeze
    LIMIT_FIELDS = %w[max_frame max_message_heap funnel_depth exports tmp overlay atoms foreign_atoms processes
                      peer_held peer_held_total].freeze

    def initialize(helper:, runner:)
      unless helper.is_a?(PackTools::Helper) && helper.tool == 'domains'
        raise Error, 'domain planning requires a helper owned by PackTools.build'
      end

      @helper = helper
      @runner = runner
    end

    # view: 'machine' (max_domains, max_connections, system_lane, system_reserve,
    # system_grant), 'principals' (memory, domains, grant, default_limits,
    # ceiling_limits), 'files' (kind, flags, image_ok, image_flags) and 'domains' (the
    # erx_dom_configured_t fields, principal numbered from 1, spaces 1 for
    # ERX_DOM_SPACES and spaces_grant its sub-space grant). Returns each domain
    # row's erx_status_t, 0 for a row the library plans.
    def call(view)
      Dir.mktmpdir('erx-dom-plan-') do |directory|
        input = File.join(directory, 'view.txt')
        File.binwrite(input, self.class.input(view))
        record = @helper.run([input], runner: @runner, name: 'dom-plan', deadline: 60)
        self.class.statuses(File.binread(record.fetch('log')), rows: view.fetch('domains').size)
      end
    end

    def self.input(view)
      machine = view.fetch('machine')
      lines = [['machine', *machine.values_at('max_domains', 'max_connections', 'system_lane', 'system_reserve'),
                *grant(machine.fetch('system_grant'))]]
      lines.concat(view.fetch('principals').map do |row|
        ['principal', row.fetch('memory'), row.fetch('domains'), *grant(row.fetch('grant')),
         *limits(row.fetch('default_limits')), *limits(row.fetch('ceiling_limits'))]
      end)
      lines.concat(view.fetch('files').map { |row| ['file', *row.values_at('kind', 'flags', 'image_ok', 'image_flags')] })
      lines.concat(view.fetch('domains').map do |row|
        ['domain', *%w[principal spaces release release_files runtime memory outer].map { |key| row.fetch(key) },
         *grant(row.fetch('grant')), *grant(row.fetch('spaces_grant')), *limits(row.fetch('runtime_limits')),
         row.fetch('lane'), row.fetch('connections')]
      end)
      lines.map { |words| "#{words.join(' ')}\n" }.join
    end

    # The helper's reply: `domain ROW STATUS` for each row in order, and nothing else.
    def self.statuses(bytes, rows:)
      lines = bytes.b.lines
      unless lines.size == rows && lines.each_with_index.all? { |line, index| line.match?(/\Adomain #{index} -?[0-9]+\n\z/) }
        raise Error, 'domain planner reply is not one status per row'
      end

      lines.map { |line| Integer(line.split.last, 10) }
    end

    def self.grant(values) = GRANT_FIELDS.map { |field| values.fetch(field) }
    def self.limits(values) = LIMIT_FIELDS.map { |field| values.fetch(field) }
    private_class_method :grant, :limits
  end
end
