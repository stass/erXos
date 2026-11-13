# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'json_input'
require_relative 'origin'

module Erx
  # Reviewed document references supplement the immutable import inventory.
  # Package overrides select the legal text for the chosen grant, including
  # nested vendored libraries; filenames have no inferred license meaning.
  module ImportNotices
    module_function

    def parse(bytes)
      value = JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'import notice profile')
      unless value.is_a?(Hash) && value.keys.sort == %w[licenses packages version] && value['version'] == 1 &&
             value['packages'].is_a?(Array) && value['packages'].size <= 256
        raise Error, 'invalid import notice profile'
      end
      licenses(value.fetch('licenses'))
      paths = value.fetch('packages').map do |package|
        unless package.is_a?(Hash) && package.keys.sort == %w[grants notices path]
          raise Error, 'invalid notice package record'
        end
        path(package.fetch('path'))
        references(package.fetch('notices'))
        licenses(package.fetch('grants'))
        package.fetch('path')
      end
      raise Error, 'duplicate notice package path' unless paths.uniq == paths
      freeze_value(value)
    end

    def select(profile, source:, grants:)
      packages = profile.fetch('packages').select do |package|
        source == package.fetch('path') || source.start_with?(package.fetch('path') + '/')
      end.sort_by { |package| -package.fetch('path').bytesize }
      notices = packages.flat_map { |package| package.fetch('notices') }
      grants.each do |grant|
        package = packages.find { |candidate| candidate.fetch('grants').key?(grant) }
        chosen = package ? package.fetch('grants').fetch(grant) : profile.fetch('licenses').fetch(grant, [])
        notices.concat(chosen)
      end
      notices.uniq.freeze
    end

    def documents(profile)
      values = profile.fetch('licenses').values.flatten + profile.fetch('packages').flat_map do |package|
        package.fetch('notices') + package.fetch('grants').values.flatten
      end
      values.uniq.freeze
    end

    def licenses(value)
      raise Error, 'invalid notice grant map' unless value.is_a?(Hash) && value.size <= 256
      value.each do |grant, docs|
        Attribution.validate_expression(grant)
        raise Error, 'notice map keys must name single grants' unless (grant.split & %w[AND OR]).empty?
        references(docs)
        raise Error, 'notice grant has no document' if docs.empty?
      end
    end
    private_class_method :licenses

    def references(value)
      raise Error, 'invalid notice document list' unless value.is_a?(Array) && value.size <= 64
      value.each do |reference|
        unless reference.is_a?(Hash) && reference.keys.sort == %w[path sha256] &&
               reference['sha256'].is_a?(String) && reference['sha256'].match?(/\A[0-9a-f]{64}\z/)
          raise Error, 'invalid notice document reference'
        end
        path(reference.fetch('path'))
      end
      raise Error, 'duplicate notice document reference' unless value.uniq == value
    end
    private_class_method :references

    def path(value)
      unless value.is_a?(String) && value.ascii_only? && value.bytesize.between?(1, 4096) &&
             value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.+\/-]*\z/) &&
             value.split('/', -1).none? { |component| ['', '.', '..'].include?(component) }
        raise Error, 'invalid project-relative notice path'
      end
    end
    private_class_method :path

    def freeze_value(value)
      case value
      when Hash then value.each { |key, member| freeze_value(key); freeze_value(member) }
      when Array then value.each { |member| freeze_value(member) }
      end
      value.freeze
    end
    private_class_method :freeze_value
  end
end
