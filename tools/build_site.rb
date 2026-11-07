#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Assembles the website in build/site (see site/README.md) and, with
# --serve, serves it on 127.0.0.1.

require 'optparse'
require_relative 'lib/erx/site'

root = File.expand_path('..', __dir__)
options = { image: File.join(root, 'build/production-image/interactive/image.boot'),
            out: File.join(root, 'build/site'), v64: nil, serve: nil }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/build_site.rb [--v64 DIR] [--image PATH] [--out DIR] [--serve PORT]'
  flags.on('--v64 DIR', 'a v64 tree already built (default: build the fetched, pinned v64)') do |path|
    options[:v64] = File.expand_path(path)
  end
  flags.on('--image PATH', 'erXos boot image (default: the interactive production image)') do |path|
    options[:image] = File.expand_path(path)
  end
  flags.on('--out DIR', 'output directory (default: build/site)') { |path| options[:out] = File.expand_path(path) }
  flags.on('--serve PORT', Integer, 'serve the result on 127.0.0.1:PORT') { |port| options[:serve] = port }
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
  v64 = options[:v64] || Erx::Site.build_v64(root:)
  plan = Erx::Site.plan(root:, v64:, image: options.fetch(:image))
  manifest = Erx::Site.publish(plan, out: options.fetch(:out))
  puts "Site: #{options.fetch(:out)} (image #{manifest.fetch(:bytes)} bytes, " \
       "#{manifest.fetch(:compressed_bytes)} compressed)"
  Erx::Site.serve(dir: options.fetch(:out), port: options.fetch(:serve)) if options[:serve]
rescue OptionParser::ParseError, Erx::Error => error
  warn error.message
  exit 1
rescue Interrupt
  exit 0
end
