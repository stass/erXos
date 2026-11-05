#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Writes erlang/apps/erx_files/src/erx_ramfs_serving.erl, the modules /tmp's serving
# processes can call, from xref over a built runtime's OTP copy (Erx::ServingSet).
# Usage: tools/gen_ramfs_serving.rb [OTP_COPY]; the runtime's copy by default. ERX_ERL
# names the host erl, the oracle's by default. Rebuild the runtime after it, since the
# list is itself one of erx_files' modules.

require_relative 'lib/erx/runtime'
require_relative 'lib/erx/serving_set'

root = File.expand_path('..', __dir__)
otp = ARGV.fetch(0) { Erx::Runtime.output(root: root).root }
erl = ENV.fetch('ERX_ERL') { File.join(root, 'build/oracle/jit/install/bin/erl') }
modules = Erx::ServingSet.closure(erl: erl, directories: Erx::ServingSet.directories(otp: otp), root: root)
File.write(File.join(root, Erx::ServingSet::GENERATED), Erx::ServingSet.render(modules))
puts "#{Erx::ServingSet::GENERATED}: #{modules.size} modules"
