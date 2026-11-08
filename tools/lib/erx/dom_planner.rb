# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'pack_tools'

module Erx
  # The manifest check's run of the domain library's planner (docs/design-system.md,
  # "The manifest", property 12): the host build of the library (tools/host/dom_plan.c)
  # plans each configured domain in boot order, then each introduction, against a
  # model machine that records every plan it makes. This boundary writes the view as
  # the helper's text input and reads back one status per domain and per
  # introduction; the input format is the helper's header comment.
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
    # erx_dom_configured_t fields in boot order, principal numbered from 1, spaces 1
    # for ERX_DOM_SPACES and spaces_grant its sub-space grant) and 'introductions'
    # (a and b, each a place in 'domains'). Returns 'domains' and 'introductions',
    # each entry's erx_status_t in its list's order, 0 for one the library plans.
    def call(view)
      Dir.mktmpdir('erx-dom-plan-') do |directory|
        input = File.join(directory, 'view.txt')
        File.binwrite(input, self.class.input(view))
        record = @helper.run([input], runner: @runner, name: 'dom-plan', deadline: 60)
        self.class.statuses(File.binread(record.fetch('log')), domains: view.fetch('domains').size,
                                                                introductions: view.fetch('introductions').size)
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
      lines.concat(view.fetch('introductions').map { |row| ['introduce', *row.values_at('a', 'b')] })
      lines.map { |words| "#{words.join(' ')}\n" }.join
    end

    # The helper's reply: `domain N STATUS` for each domain in order, then
    # `introduce N STATUS` for each introduction, and nothing else.
    def self.statuses(bytes, domains:, introductions:)
      expected = [['domain'] * domains, ['introduce'] * introductions].flat_map { |kinds| kinds.each_with_index.to_a }
      lines = bytes.b.lines
      unless lines.size == expected.size &&
             lines.zip(expected).all? { |line, (kind, index)| line.match?(/\A#{kind} #{index} -?[0-9]+\n\z/) }
        raise Error, 'domain planner reply is not one status per domain and introduction'
      end

      statuses = lines.map { |line| Integer(line.split.last, 10) }
      { 'domains' => statuses.first(domains), 'introductions' => statuses.drop(domains) }
    end

    def self.grant(values) = GRANT_FIELDS.map { |field| values.fetch(field) }
    def self.limits(values) = LIMIT_FIELDS.map { |field| values.fetch(field) }
    private_class_method :grant, :limits
  end
end
