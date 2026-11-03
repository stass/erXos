# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'rexml/parsers/pullparser'
require 'rexml/text'
require_relative 'runner'
require_relative 'json_input'

module Erx
  # Controller observations own execution identity and status. Common Test's
  # independent events and totals cross-check them; XML is optional metadata.
  module OracleResults
    MAX_XML_BYTES = 16 * 1024 * 1024
    MAX_EVENTS_BYTES = 32 * 1024 * 1024
    MAX_ELEMENTS = 200_000
    MAX_DEPTH = 32
    MAX_DETAIL = 64 * 1024
    MAX_DURATION_SECONDS = 86_400
    CONFIG_CASES = %w[init_per_suite end_per_suite init_per_group end_per_group].freeze
    STATES = %w[passed failed user_skip auto_skip].freeze

    module_function

    def read(xml:, events:, command:)
      evidence = read_events(events)
      observed_cases = controller_cases(evidence)
      selection = selected_jobs(evidence)
      independent = case_lifecycle(evidence)
      cases = observed_cases.fetch('cases')
      counts = counts_for(cases.select { |record| record.fetch('kind') == 'testcase' })
      common_test_counts = counts_for(cases)
      suite_skip_counts = counts_for(cases.select { |record| record.fetch('kind') == 'suite_skip' })
      observed = evidence.reverse.find { |event| event.fetch('event') == 'test_stats' }
      completed = evidence.any? { |event| event.fetch('event') == 'test_done' }
      started = evidence.any? { |event| event.fetch('event') == 'test_start' }
      reconciled = observed && common_test_counts.all? { |status, count| observed[status] == count }
      matched = identity_counts(cases) == identity_counts(independent.fetch('cases')) &&
                configuration_counts(cases) == configuration_counts(independent.fetch('cases'))
      complete = started && completed && reconciled && matched && !cases.empty? &&
                 observed_cases.fetch('outstanding').empty? && independent.fetch('outstanding').empty? &&
                 selection.fetch('complete')
      metadata = attach_xml(cases, xml: xml)
      state = if command.fetch('state') == 'timed_out'
                'timed_out'
              elsif !complete
                'incomplete'
              elsif command.fetch('state') != 'succeeded' || cases.any? { |record| record.fetch('status') == 'failed' }
                'failed'
              else
                'completed'
              end
      { 'state' => state, 'complete' => !!complete, 'counts' => counts,
        'common_test_counts' => common_test_counts, 'suite_skip_counts' => suite_skip_counts,
        'selection' => selection.reject { |key, _| key == 'jobs' }, 'selected_jobs' => selection.fetch('jobs'),
        'observed_counts' => observed, 'cases' => cases,
        'reporter' => 'common_test_controller', 'metadata' => metadata,
        'partial_events' => complete ? [] : evidence, 'command' => command,
        'junit_report' => xml, 'event_report' => events }
    end

    # One reference belongs to one execution. A terminal event can only finish
    # that reference; repetitions and parallel cases never share mutable state.
    def controller_cases(events)
      records = {}
      attempts = Hash.new(0)
      group_bindings = {}
      events.each do |event|
        case event.fetch('event')
        when 'case_start'
          token = event.fetch('id')
          raise Error, 'duplicate controller case start' if records.key?(token)
          groups = event.fetch('groups')
          bind_groups(groups, bindings: group_bindings)
          key = [event.fetch('suite'), groups.map { |group| group.fetch('name') }.compact, event.fetch('testcase')]
          records[token] = { 'id' => token, 'suite' => event.fetch('suite'),
            'testcase' => event.fetch('testcase'), 'groups' => groups,
            'group' => groups.map { |group| group.fetch('name') }.compact,
            'attempt' => attempts[key] += 1, 'status' => 'incomplete',
            'kind' => 'unknown', 'number' => nil,
            'configuration' => CONFIG_CASES.include?(event.fetch('testcase')),
            'log' => event.fetch('log'), 'detail' => '' }
        when 'case_finish'
          record = records[event.fetch('id')]
          raise Error, 'controller case finished without its start' unless record
          raise Error, 'duplicate controller case finish' unless record.fetch('status') == 'incomplete'
          record['status'] = event.fetch('status')
          record['number'] = event.fetch('number')
          record['kind'] = if record.fetch('number').positive?
                             'testcase'
                           elsif record.fetch('testcase') == 'all' && %w[user_skip auto_skip].include?(record.fetch('status'))
                             'suite_skip'
                           else
                             'configuration'
                           end
          record['configuration'] = record.fetch('kind') == 'configuration'
          record['detail'] = event.fetch('detail')
        end
      end
      cases = records.values
      { 'cases' => cases, 'outstanding' => cases.select { |record| record.fetch('status') == 'incomplete' } }
    end
    private_class_method :controller_cases

    def selected_jobs(events)
      jobs = {}
      workers = {}
      pending = {}
      selection = nil
      sealed = false
      closure = nil
      valid = true
      events.each do |event|
        kind = event.fetch('event')
        case kind
        when 'selection_begin'
          raise Error, 'duplicate controller selection' if selection
          selection = event.fetch('id')
        when 'job_selected'
          raise Error, 'controller job selected outside its roster' unless selection == event.fetch('selection') && !sealed
          reference = event.fetch('id')
          raise Error, 'duplicate selected controller job' if jobs.key?(reference)
          jobs[reference] = { 'id' => reference, 'name' => event.fetch('name'), 'state' => 'selected' }
        when 'selection_seal'
          raise Error, 'invalid controller selection seal' unless selection == event.fetch('id') && !sealed && event.fetch('count') == jobs.size
          sealed = true
        when 'job_admitted'
          job = jobs[event.fetch('id')]
          raise Error, 'unselected or repeated controller job admission' unless sealed && job && job.fetch('state') == 'selected'
          job['state'] = 'admitted'
        when 'job_worker'
          job = jobs[event.fetch('id')]
          worker = event.fetch('worker')
          raise Error, 'invalid controller job worker' unless job && job.fetch('state') == 'admitted' && !workers.key?(worker)
          workers[worker] = job
          job.merge!('state' => 'running', 'worker' => worker)
        when 'case_start'
          job = workers[event.fetch('worker')]
          valid = false unless job && job.fetch('state') == 'running'
          pending[event.fetch('id')] = job && job.fetch('id')
        when 'case_finish'
          owner = pending.delete(event.fetch('id'))
          valid = false unless owner && jobs.fetch(owner).fetch('state') == 'running'
        when 'job_traversed'
          job = workers[event.fetch('worker')]
          if job && job.fetch('state') == 'running' && !pending.value?(job.fetch('id'))
            job['state'] = 'traversed'
          else
            valid = false
          end
        when 'job_exit'
          job = workers[event.fetch('worker')]
          raise Error, 'controller job exit changed identity' unless job && job.fetch('id') == event.fetch('id')
          job['state'] = job.fetch('state') == 'traversed' && event.fetch('normal') ? 'completed' : 'failed'
          workers.delete(event.fetch('worker'))
        when 'selection_close'
          raise Error, 'controller closure names another selection' unless selection == event.fetch('id')
          closure = event.fetch('normal') && closure != 'aborted' ? 'normal' : 'aborted'
        when 'selection_error'
          valid = false
        end
      end
      complete = valid && sealed && closure == 'normal' && !jobs.empty? &&
                 jobs.values.all? { |job| job.fetch('state') == 'completed' } && pending.empty? && workers.empty?
      { 'id' => selection, 'sealed' => sealed, 'closure' => closure,
        'complete' => !!complete, 'jobs' => jobs.values }
    end
    private_class_method :selected_jobs

    def bind_groups(groups, bindings:)
      parent = nil
      seen = {}
      groups.each do |group|
        reference = group.fetch('id')
        raise Error, 'cyclic controller group path' if seen[reference]
        seen[reference] = true
        binding = [parent, group.fetch('name')]
        if bindings.key?(reference) && bindings.fetch(reference) != binding
          raise Error, 'controller group reference changed identity'
        end
        bindings[reference] = binding.freeze
        parent = reference
      end
    end
    private_class_method :bind_groups

    # Optional XML must name a unique actual execution and the identical log.
    # Surplus, missing or broken XML cannot create cases or change their result.
    def attach_xml(cases, xml:)
      return { 'state' => 'absent' } unless xml && File.file?(xml)
      metadata = parse_xml(read_bounded(xml, limit: MAX_XML_BYTES))
      candidates = metadata.group_by { |record| [record.fetch('suite'), record.fetch('testcase'), record.fetch('log')] }
      executions = cases.group_by { |record| [record.fetch('suite'), record.fetch('testcase'), record.fetch('log')] }
      cases.each do |record|
        next unless record['log']
        key = [record.fetch('suite'), record.fetch('testcase'), record.fetch('log')]
        next unless executions.fetch(key).size == 1
        matches = candidates[key]
        next unless matches && matches.size == 1 && matches.first.fetch('status') == record.fetch('status')
        duration = matches.first.fetch('seconds')
        record['seconds'] = duration if valid_duration?(duration)
      end
      { 'state' => 'available', 'rows' => metadata.size }
    rescue Error => error
      { 'state' => 'invalid', 'diagnostic' => error.message }
    end
    private_class_method :attach_xml

    def valid_duration?(text)
      return false unless text.is_a?(String) && text.bytesize.between?(1, 64) &&
                          /\A[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/.match?(text)
      value = Float(text)
      value.finite? && value.between?(0, MAX_DURATION_SECONDS)
    end
    private_class_method :valid_duration?

    def parse_xml(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, 'oracle XML is not valid UTF-8' unless text.valid_encoding?
      raise Error, 'oracle XML exceeds byte bound' if text.bytesize > MAX_XML_BYTES
      if text.match?(/<!\s*(?:DOCTYPE|ENTITY)/i)
        raise Error, 'oracle XML declarations and entities are forbidden'
      end
      if text.scan(/&([A-Za-z_:][A-Za-z0-9_.:\-]*);/).flatten.any? { |name| !%w[amp lt gt quot apos].include?(name) }
        raise Error, 'unknown oracle XML entity'
      end
      validate_xml_characters(text)
      declaration = /\A(?:\uFEFF)?<\?xml\s+([^?]*)\?>/.match(text)
      if declaration && (encoding = /encoding\s*=\s*['"]([^'"]+)['"]/.match(declaration[1])) &&
         encoding[1].upcase != 'UTF-8'
        raise Error, 'unsupported oracle XML encoding'
      end

      parser = REXML::Parsers::PullParser.new(text)
      stack = []
      cases = []
      suites = []
      current_suite = nil
      current_case = nil
      detail = nil
      elements = 0
      roots = 0
      attempts = Hash.new(0)
      while parser.has_next?
        event = parser.pull
        case event.event_type
        when :start_element
          elements += 1
          raise Error, 'oracle XML has too many elements' if elements > MAX_ELEMENTS
          raise Error, 'oracle XML nesting exceeds bound' if stack.size >= MAX_DEPTH
          name = event[0]
          attributes = event[1].transform_values do |value|
            normalized = REXML::Text.unnormalize(value)
            validate_xml_characters(normalized)
            normalized
          end
          validate_parent(name, parent: stack.last)
          stack << name
          case name
          when 'testsuites'
            roots += 1
            raise Error, 'oracle XML has multiple roots' if roots > 1
          when 'testsuite'
            current_suite = suite_record(attributes)
          when 'testcase'
            current_case = case_record(attributes, suite: current_suite.fetch('name'), attempts: attempts)
          when 'failure', 'skipped', 'error'
            raise Error, 'oracle case has multiple result elements' if current_case.key?('detail')
            detail = name
            current_case['detail'] = String.new
            current_case['status'] = name == 'skipped' ? 'skipped' : 'failed'
          end
        when :text, :cdata
          text_value = event.event_type == :text ? event[1] : event[0]
          validate_xml_characters(text_value)
          unless detail
            raise Error, 'unexpected text in oracle XML' unless text_value.strip.empty?
            next
          end
          current_case['detail'] << text_value
          raise Error, 'oracle case detail exceeds bound' if current_case.fetch('detail').bytesize > MAX_DETAIL
        when :end_element
          name = event[0]
          raise Error, 'oracle XML closing element mismatch' unless stack.pop == name
          case name
          when 'failure', 'skipped', 'error'
            detail = nil
          when 'testcase'
            finish_case(current_case)
            cases << current_case
            current_suite.fetch('cases') << current_case
            current_case = nil
          when 'testsuite'
            validate_suite(current_suite)
            suites << current_suite
            current_suite = nil
          end
        when :xmldecl, :comment, :processing_instruction
          next
        else
          raise Error, "unsupported oracle XML event: #{event.event_type}"
        end
      end
      raise Error, 'oracle XML is incomplete' unless stack.empty? && !suites.empty?
      cases
    rescue REXML::ParseException, RangeError, ArgumentError => error
      raise Error, "invalid oracle XML: #{error.message}"
    end

    def validate_xml_characters(text)
      text.each_codepoint do |point|
        valid = [9, 10, 13].include?(point) || point.between?(0x20, 0xd7ff) ||
                point.between?(0xe000, 0xfffd) || point.between?(0x10000, 0x10ffff)
        raise Error, 'invalid oracle XML character' unless valid
      end
    end
    private_class_method :validate_xml_characters

    def validate_parent(name, parent:)
      expected = { 'testsuites' => nil, 'testsuite' => 'testsuites',
                   'testcase' => 'testsuite', 'properties' => 'testsuites',
                   'property' => 'properties', 'failure' => 'testcase',
                   'error' => 'testcase', 'skipped' => 'testcase' }
      unless expected.key?(name) && expected.fetch(name) == parent
        raise Error, "unsupported oracle XML element or parent: #{name}"
      end
    end
    private_class_method :validate_parent

    def suite_record(attributes)
      { 'name' => required_string(attributes, 'name'),
        'tests' => decimal(attributes, 'tests'), 'failures' => decimal(attributes, 'failures'),
        'skipped' => decimal(attributes, 'skipped'), 'errors' => decimal(attributes, 'errors'),
        'cases' => [] }
    end
    private_class_method :suite_record

    def case_record(attributes, suite:, attempts:)
      name = required_string(attributes, 'name')
      group = attributes.fetch('group', '')
      identity = [suite, group, name]
      attempts[identity] += 1
      { 'suite' => suite, 'group' => group, 'testcase' => name,
        'attempt' => attempts.fetch(identity), 'status' => 'passed',
        'configuration' => CONFIG_CASES.include?(name), 'log' => attributes.fetch('log', ''),
        'seconds' => attributes.fetch('time', '') }
    end
    private_class_method :case_record

    def finish_case(record)
      return unless record.fetch('status') == 'skipped'
      reason = record.fetch('detail').lstrip
      record['status'] = if reason.start_with?('{tc_auto_skip,')
                           'auto_skip'
                         elsif reason.start_with?('{tc_user_skip,')
                           'user_skip'
                         else
                           raise Error, 'oracle skip lacks its Common Test classification'
                         end
    end
    private_class_method :finish_case

    def validate_suite(suite)
      cases = suite.fetch('cases').reject { |record| record.fetch('configuration') }
      counts = counts_for(cases)
      unless suite.fetch('tests') == cases.size &&
             suite.fetch('failures') == counts.fetch('failed') &&
             suite.fetch('skipped') == counts.fetch('user_skip') + counts.fetch('auto_skip') &&
             suite.fetch('errors').zero?
        raise Error, "oracle suite totals disagree with cases: #{suite.fetch('name')}"
      end
    end
    private_class_method :validate_suite

    def counts_for(cases)
      counts = STATES.to_h { |state| [state, 0] }
      cases.reject { |record| record.fetch('configuration') }.each do |record|
        status = record.fetch('status')
        counts[status] += 1 if counts.key?(status)
      end
      counts
    end

    def required_string(attributes, name)
      value = attributes[name]
      raise Error, "missing oracle XML attribute: #{name}" unless value.is_a?(String) && !value.empty?
      value
    end
    private_class_method :required_string

    def decimal(attributes, name)
      value = required_string(attributes, name)
      raise Error, "invalid oracle XML count: #{name}" unless /\A[0-9]{1,9}\z/.match?(value)
      value.to_i
    end
    private_class_method :decimal

    def read_bounded(path, limit:)
      bytes = File.binread(path, limit + 1)
      raise Error, "oracle report exceeds byte bound: #{path}" if bytes.bytesize > limit
      bytes
    end
    private_class_method :read_bounded

    def read_events(path)
      return [] unless File.file?(path)
      events = read_bounded(path, limit: MAX_EVENTS_BYTES).lines.map do |line|
        raise Error, 'oracle event exceeds byte bound' if line.bytesize > 32 * 1024
        event = JsonInput.parse(line, max_bytes: 32 * 1024, label: 'oracle completion event')
        unless event.is_a?(Hash) && event['event'].is_a?(String)
          raise Error, 'invalid oracle completion event'
        end
        if event.fetch('event') == 'test_stats'
          STATES.each do |state|
            value = event[state]
            raise Error, 'invalid oracle event count' unless value.is_a?(Integer) && value.between?(0, 1_000_000)
          end
        end
        validate_event_fields(event)
        event
      end
      validate_event_order(events)
      events
    end
    private_class_method :read_events

    def validate_event_fields(event)
      kind = event.fetch('event')
      expected = case kind
                 when 'test_start', 'test_done' then ['event']
                 when 'test_stats' then ['event', *STATES]
                 when 'case_start' then %w[event id worker suite testcase groups log]
                 when 'case_finish' then %w[event id status number detail]
                 when 'selection_begin', 'selection_error', 'job_admitted' then %w[event id]
                 when 'selection_seal' then %w[event id count]
                 when 'selection_close' then %w[event id normal]
                 when 'job_selected' then %w[event id selection name]
                 when 'job_worker' then %w[event id worker]
                 when 'job_traversed' then %w[event worker]
                 when 'job_exit' then %w[event id worker normal]
                 when 'tc_start' then %w[event suite testcase group]
                 when 'tc_done' then %w[event suite testcase group result detail]
                 when 'tc_user_skip', 'tc_auto_skip' then %w[event suite testcase group detail]
                 else raise Error, 'unsupported oracle event'
                 end
      raise Error, 'unexpected oracle event fields' unless event.keys.sort == expected.sort
      if event.key?('id')
        token = event.fetch('id')
        unless token.is_a?(String) && /\A#Ref<[0-9.]+>\z/.match?(token) && token.bytesize <= 128
          raise Error, 'invalid controller case reference'
        end
      end
      if event.key?('selection') && !(event['selection'].is_a?(String) && /\A#Ref<[0-9.]+>\z/.match?(event['selection']) && event['selection'].bytesize <= 128)
        raise Error, 'invalid controller selection reference'
      end
      if event.key?('worker') && !(event['worker'].is_a?(String) && /\A<[0-9.]+>\z/.match?(event['worker']) && event['worker'].bytesize <= 128)
        raise Error, 'invalid controller worker'
      end
      if event.key?('normal') && ![true, false].include?(event['normal'])
        raise Error, 'invalid controller closure status'
      end
      if kind == 'selection_seal' && !(event['count'].is_a?(Integer) && event['count'].between?(0, 100_000))
        raise Error, 'invalid selected job count'
      end
      if kind == 'job_selected' && !(event['name'].is_a?(String) && event['name'].bytesize.between?(1, 4096))
        raise Error, 'invalid selected job name'
      end
      if kind == 'case_start'
        %w[suite testcase].each do |field|
          value = event.fetch(field)
          raise Error, 'invalid controller case name' unless value.is_a?(String) && value.bytesize.between?(1, 4096)
        end
        groups = event.fetch('groups')
        unless groups.is_a?(Array) && groups.size <= 64 && groups.all? do |group|
          group.is_a?(Hash) && group.keys.sort == %w[id name] &&
            group['id'].is_a?(String) && /\A#Ref<[0-9.]+>\z/.match?(group['id']) && group['id'].bytesize <= 128 &&
            (group['name'].nil? || (group['name'].is_a?(String) && group['name'].bytesize.between?(1, 4096)))
        end
          raise Error, 'invalid controller group path'
        end
        log = event.fetch('log')
        unless log.nil? || (log.is_a?(String) && log.bytesize.between?(1, 4096))
          raise Error, 'invalid controller case log'
        end
      elsif kind == 'case_finish'
        unless STATES.include?(event['status']) && event['number'].is_a?(Integer) && event['number'].between?(0, 1_000_000)
          raise Error, 'invalid controller case result'
        end
      end
      if kind.start_with?('tc_')
        %w[suite testcase].each do |field|
          value = event.fetch(field)
          raise Error, 'invalid oracle case identity' unless value.is_a?(String) && value.bytesize.between?(1, 4096)
        end
        group = event.fetch('group')
        unless group.nil? || (group.is_a?(String) && group.bytesize.between?(1, 4096))
          raise Error, 'invalid oracle event group'
        end
      end
      if event.key?('detail') && !event.fetch('detail').is_a?(String)
        raise Error, 'invalid oracle case detail'
      end
      if kind == 'tc_done' && !%w[passed failed skipped auto_skip error].include?(event.fetch('result'))
        raise Error, 'invalid oracle case result'
      end
    end
    private_class_method :validate_event_fields

    def validate_event_order(events)
      phase = 'unstarted'
      events.each do |event|
        case event.fetch('event')
        when 'test_start'
          raise Error, 'duplicate or late oracle start event' unless phase == 'unstarted'
          phase = 'running'
        when 'test_done'
          raise Error, 'oracle completion without an active run' unless phase == 'running'
          phase = 'completed'
        when 'test_stats', 'tc_start', 'tc_done', 'tc_user_skip', 'tc_auto_skip', 'case_start', 'case_finish'
          raise Error, 'oracle case or totals outside active run' unless phase == 'running'
        when 'selection_begin', 'selection_seal', 'selection_close', 'selection_error', 'job_selected', 'job_admitted', 'job_worker', 'job_traversed', 'job_exit'
          raise Error, 'controller selection event after run completion' if phase == 'completed'
        else
          raise Error, 'unsupported oracle event'
        end
      end
    end
    private_class_method :validate_event_order

    def case_lifecycle(events)
      pending = Hash.new { |hash, key| hash[key] = [] }
      attempts = Hash.new(0)
      cases = []
      events.each do |event|
        kind = event.fetch('event')
        next unless %w[tc_start tc_done tc_user_skip tc_auto_skip].include?(kind)
        suite = event.fetch('suite')
        testcase = event.fetch('testcase')
        group = event.fetch('group')
        key = [suite, testcase, group]
        if kind == 'tc_start'
          attempts[key] += 1
          pending[key] << { 'suite' => suite, 'group' => nil, 'group_leaf' => group, 'testcase' => testcase,
                            'attempt' => attempts.fetch(key), 'status' => 'incomplete',
                            'configuration' => CONFIG_CASES.include?(testcase),
                            'group_status' => 'unknown' }
          next
        end
        record = pending[key].shift
        if record.nil?
          raise Error, 'oracle case ended without a start' if kind == 'tc_done'
          attempts[key] += 1
          record = { 'suite' => suite, 'group' => nil, 'group_leaf' => group, 'testcase' => testcase,
                     'attempt' => attempts.fetch(key), 'configuration' => CONFIG_CASES.include?(testcase),
                     'group_status' => 'unknown' }
        end
        record['status'] = if kind == 'tc_user_skip'
                             'user_skip'
                           elsif kind == 'tc_auto_skip'
                             'auto_skip'
                           elsif STATES.include?(event['result'])
                             event.fetch('result')
                           else
                             'unknown'
                           end
        record['detail'] = event.fetch('detail')
        record['event_result'] = event['result']
        cases << record
      end
      { 'cases' => cases, 'outstanding' => pending.values.flatten }
    rescue KeyError => error
      raise Error, "incomplete oracle case event: #{error.message}"
    end
    private_class_method :case_lifecycle

    def identity_counts(cases)
      # The controller owns user/auto classification. Independent tc_done can
      # report generic skipped, so compare broad outcomes per case here.
      cases.each_with_object(Hash.new(0)) do |record, counts|
        next if record.fetch('configuration')
        status = record.fetch('status')
        status = 'skipped' if %w[user_skip auto_skip].include?(status) || record['event_result'] == 'skipped'
        counts[[record.fetch('suite'), record.fetch('testcase'), status]] += 1
      end
    end
    private_class_method :identity_counts

    def configuration_counts(cases)
      # CT's default callbacks emit ct_framework as the event module, while
      # the controller's Mode resolves the suite. Compare phase/outcome counts
      # without inventing a suite identity absent from those default events.
      cases.each_with_object(Hash.new(0)) do |record, counts|
        next unless record.fetch('configuration')
        status = record.fetch('status')
        if %w[user_skip auto_skip].include?(status) || record['event_result'] == 'skipped'
          status = 'skipped'
        end
        counts[[record.fetch('testcase'), status]] += 1
      end
    end
    private_class_method :configuration_counts
  end
end
