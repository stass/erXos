# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'json_input'
require_relative 'pack_tools'
require 'digest'

module Erx
  # The C planner alone interprets executable headers. This boundary checks the
  # shape and extents of its reply before Ruby copies any executable bytes.
  class ElfPlanner
    FIELDS = %w[abi_version virtual_origin fixed_base span entry phdr_offset output_size flags phnum base_alignment loads].freeze
    LOAD_FIELDS = %w[source_offset file_offset mem_offset file_size mem_size prot flags].freeze

    def initialize(helper:, runner:, codec:)
      unless helper.is_a?(PackTools::Helper) && helper.tool == "planner"
        raise Error, "ELF planning requires a helper owned by PackTools.build"
      end
      @helper = helper
      @runner = runner
      @codec = codec
    end

    def call(path, budget:)
      record = @helper.run([path, budget.to_s], runner: @runner, name: "elf-plan", deadline: 30)
      self.class.decode(File.binread(record.fetch("log")), codec: @codec,
                        source_size: File.size(path), budget: budget)
    end

    def self.decode(bytes, codec:, source_size:, budget:)
      plan = JsonInput.parse(bytes, max_bytes: 32_768, label: 'ELF plan reply')
      numeric_record(plan, FIELDS - ['loads'], FIELDS)
      raise Error, 'ELF planner ABI version differs from packer' unless plan.fetch('abi_version') == codec.abi_version
      loads = plan.fetch('loads')
      unless loads.is_a?(Array) && loads.size.between?(1, codec.constant('elf_segments_max'))
        raise Error, 'invalid ELF plan load count'
      end
      page = codec.constant('page_size')
      unless plan.fetch('output_size').between?(page, budget) &&
             plan.fetch('span').between?(page, codec.constant('image_span_max')) &&
             plan.fetch('entry') < plan.fetch('span') && plan.fetch('phnum').positive?
        raise Error, 'invalid ELF plan image extent'
      end
      alignment = plan.fetch('base_alignment')
      unless alignment >= page && (alignment & (alignment - 1)).zero? && alignment <= 0xffff_ffff
        raise Error, 'invalid ELF plan base alignment'
      end
      cursor = page
      previous_end = 0
      loads.each do |load|
        numeric_record(load, LOAD_FIELDS, LOAD_FIELDS)
        file_size = load.fetch('file_size')
        memory_size = load.fetch('mem_size')
        offset = load.fetch('mem_offset')
        protection = load.fetch('prot')
        unless file_size <= memory_size && memory_size.positive? &&
               load.fetch('source_offset') <= source_size &&
               file_size <= source_size - load.fetch('source_offset') &&
               offset >= previous_end && offset % page == 0 &&
               memory_size <= plan.fetch('span') - offset &&
               %w[r rw rx].map { |member| codec.member('prot', member) }.include?(protection) &&
               load.fetch('file_offset') == cursor && load.fetch('flags').zero?
          raise Error, 'invalid ELF plan segment extent'
        end
        stored = protection == codec.member('prot', 'rw') ? file_size : memory_size
        cursor += ((stored + page - 1) / page) * page
        previous_end = offset + ((memory_size + page - 1) / page) * page
        load.freeze
      end
      unless cursor == plan.fetch('output_size') && previous_end == plan.fetch('span')
        raise Error, 'invalid ELF plan storage extent'
      end
      loads.freeze
      plan.freeze
    end

    def self.numeric_record(value, numbers, fields)
      unless value.is_a?(Hash) && value.keys.sort == fields.sort && numbers.all? do |key|
        value.fetch(key).is_a?(Integer) && value.fetch(key).between?(0, 0xffff_ffff_ffff_ffff)
      end
        raise Error, 'invalid ELF plan reply fields'
      end
    end
    private_class_method :numeric_record
  end
end
