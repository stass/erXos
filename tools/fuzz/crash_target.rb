# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/crash_frame'

# The crash record's writer, checker and frame codec, which share one target.
# The first byte picks the path; tools/fuzz/crash_fuzz.c describes each. Seeds
# hold a well-formed brief record and its frame, so mutations start past the
# CRC, a frame with its lines out of shape, and inputs for the writer.
frame = Erx::CrashFrame
codec = frame::CODEC
fault = { 'kind' => 0, 'cause' => 0, 'addr' => 0, 'pc' => 0, 'thread' => 0, 'space' => 0, 'status' => 0 }
fields = { 'magic' => codec.constant('crash_magic'), 'version' => codec.constant('crash_version'),
           'length' => frame::BRIEF_SIZE, 'crc' => 0, 'form' => frame::FORMS.fetch('brief'),
           'cause' => frame::CAUSE.fetch(:watchdog), 'cpu' => 1, 'uptime_ns' => 7, 'since_pet_ns' => 9,
           'build_id' => 'BUILDID8', 'boot_value' => codec.member('boot_value', 'normal'),
           'boot_slot' => codec.member('boot_slot', 'a'), 'nframes' => 0, 'fault' => fault }
blank = codec.encode_layout('erx_crash_brief', fields)
record = blank.dup
record[frame::CRC_START - 4, 4] = [frame.crc32c(blank.byteslice(frame::CRC_START..))].pack('L<')
lines = record.scan(/.{1,#{frame::LINE_BYTES}}/mn).map { |line| [line].pack('m0') }
log = ["#{frame::BEGIN_MARKER} brief #{record.bytesize}", *lines, frame::END_MARKER].join("\n") << "\n"

Erx::PackFuzz.declare_target(
  sources: %w[kernel/core/crash.c kernel/core/crash_frame.c kernel/core/crash_read.c kernel/core/log.c],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00#{record}", "\x00#{record * 2}", "\x01\x01#{"\x00" * 1000}", "\x01\x00#{record}",
     "\x02#{log}", "\x02text\r\n#{log.gsub("\n", "\r\n")}tail\n", "\x02#{log.lines[0...-1].join}",
     "\x02#{frame::BEGIN_MARKER} full 16385\n", "\x02#{frame::BEGIN_MARKER} brief 0120\n",
     "\x03\x07#{"\x00" * 200}message", "\x03\xff#{"\xff" * 300}\e[31m\nx", "\x03"]
  )
)
