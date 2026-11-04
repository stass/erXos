# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'crash_frame'

# The crash record's writer, checker and frame codec, which share one target.
# The first byte picks the path; tools/fuzz/crash_fuzz.c describes each. Seeds
# hold a well-formed brief record and its frame, so mutations start past the
# CRC, a frame with its lines out of shape, and inputs for the writer.
marker = Erx::CrashFrame::BEGIN_MARKER
record = Erx::CrashFrameFuzz.brief_record
log = Erx::CrashFrameFuzz.frame_of(record)

Erx::PackFuzz.declare_target(
  sources: %w[kernel/core/crash.c kernel/core/crash_frame.c kernel/core/crash_read.c kernel/core/log.c],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00#{record}", "\x00#{record * 2}", "\x01\x01#{"\x00" * 1000}", "\x01\x00#{record}",
     "\x02#{log}", "\x02text\r\n#{log.gsub("\n", "\r\n")}tail\n", "\x02#{log.lines[0...-1].join}",
     "\x02#{marker} full 16385\n", "\x02#{marker} brief 0120\n",
     "\x03\x07#{"\x00" * 200}message", "\x03\xff#{"\xff" * 300}\e[31m\nx", "\x03\x84#{"\xff" * 300}", "\x03"]
  )
)
