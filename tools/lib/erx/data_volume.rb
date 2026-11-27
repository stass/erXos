# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_packed'
require_relative 'bounded_file'
require_relative 'code_watch'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'generated'
require_relative 'medium_image'
require_relative 'oracle'
require_relative 'output_directory'
require_relative 'pack_tools'
require_relative 'runtime'

module Erx
  # The data partition's littlefs volume as installation writes it (docs/design-storage.md,
  # "A mount never formats"): the only place a volume is made. The guest never formats, so a medium
  # whose data partition holds no volume fails its mount, and the storage domain with it.
  #
  # The host program lfs-format (tools/host/lfs_format.c, built by PackTools from the
  # in-tree littlefs the guest's NIF builds, with the guest's geometry) formats a volume
  # of the partition's length and writes its leading blocks; the rest of a fresh volume
  # is the zeros every medium writer leaves. A medium writer places those blocks at the
  # partition's start with `pieces`.
  #
  # erXos's F2FS, which replaces littlefs at the switch (docs/design-f2fs.md, "Formatting
  # a volume" and "Replacing littlefs"), is formatted by `f2fs`: erx_f2fs_format's plan,
  # the Erlang the guest runs, run on the host's stock OTP.
  module DataVolume
    NAME = 'data.lfs'
    TOOL_DIRECTORY = 'lfs-format-tool'

    F2FS_PLAN = 'data.f2fs-plan'
    F2FS_TOOL_DIRECTORY = 'f2fs-format-tool'
    F2FS_BLOCK = 4096
    # A plan record as F2FS_EVAL writes it: the phase, the block's address in the
    # partition, big-endian, and the block.
    F2FS_RECORD = 1 + 4 + F2FS_BLOCK
    REPORT_MAX = 65_536
    # Reads the plan's arguments, runs the plan and writes its records, or prints the
    # format's refusal; any other failure prints its reason. The values reach the
    # expression as plain arguments, never as code.
    F2FS_EVAL = <<~'ERLANG'
      try
          [Path, Start, Sectors, Unit, Version, Time, Uuid] = init:get_plain_arguments(),
          Int = fun erlang:list_to_integer/1,
          Options = maps:from_list([{version, Int(Version)}, {time, Int(Time)},
                                    {uuid, binary:decode_hex(list_to_binary(Uuid))}
                                    | [{unit, Int(Unit)} || Unit =/= "default"]]),
          case erx_f2fs_format:plan(#{start => Int(Start), sectors => Int(Sectors)}, Options) of
              {ok, Phases} ->
                  ok = file:write_file(Path, [<<Phase:8, Address:32, Block/binary>>
                                              || {Phase, Blocks} <- lists:enumerate(Phases),
                                                 {Address, Block} <- Blocks]),
                  halt(0);
              {error, Failure} ->
                  io:format(standard_error, "the F2FS format refuses: ~p~n", [Failure]),
                  halt(2)
          end
      catch
          Class:Reason -> io:format(standard_error, "~p:~p~n", [Class, Reason]), halt(3)
      end.
    ERLANG

    # A formatted F2FS volume: the partition's first sector on the medium and the
    # plan's three phases, each a list of [address, block] pairs, kept apart for a
    # writer that flushes the medium between them.
    F2fsVolume = Data.define(:start, :phases) do
      # The medium's pieces that hold the volume, by sector, for an image writer, which
      # makes the medium whole before anything reads it: each block as the last phase
      # that writes it leaves it, consecutive blocks joined.
      def pieces
        final = phases.flatten(1).to_h
        final.keys.sort.slice_when { |first, second| second != first + 1 }.to_h do |run|
          [start + (run.first * F2FS_BLOCK / MediumImage::SECTOR_BYTES), run.map { |address| final.fetch(address) }.join]
        end
      end
    end

    module_function

    # Formats the volume of a data partition of data_sectors sectors as NAME in
    # directory, which the caller owns under owner_root, building lfs-format from root's
    # sources beside it; returns the volume's leading blocks as a MediumImage::FilePiece.
    # An existing NAME is refused.
    def format(root:, runner:, directory:, data_sectors:, owner_root: root, compiler: ENV.fetch('ERX_CLANG', 'clang'))
      raise Error, 'the data partition length is not a positive sector count' unless data_sectors.is_a?(Integer) && data_sectors.positive?

      tool = PackTools.build(root: root, owner_root: owner_root, directory: File.join(directory, TOOL_DIRECTORY), runner: runner,
                             compiler: compiler, tools: ['formatter']).fetch('formatter')
      path = File.join(directory, NAME)
      tool.run([data_sectors.to_s, path], runner: runner, name: 'lfs-format', deadline: 60)
      MediumImage::FilePiece.new(path: path, length: File.size(path))
    end

    # The medium's pieces that hold volume, which format returned: its blocks from the
    # data partition's first sector.
    def pieces(volume) = { MediumImage.constant('data_start') => volume }

    # Formats an F2FS volume on the partition of sectors sectors from sector start of
    # the medium (abi/medium.txt): compiles erx_f2fs and the layouts it reads with the
    # oracle's erlc into directory, which the caller owns, runs the plan with version,
    # uuid (16 bytes), time and the medium's allocation unit in bytes (unit, nil for
    # the format's default), and answers an F2fsVolume. Raises Error with what the
    # format refuses.
    def f2fs(root:, runner:, directory:, start:, sectors:, version:, uuid:, time:, unit: nil)
      erl = Oracle.new(root: root).erl_path(Runtime::HOST_OTP_FLAVOUR)
      compile = ErlangCompile.new(erlc: File.join(File.dirname(erl), 'erlc'), root: root, runner: runner)
      beams = File.join(directory, F2FS_TOOL_DIRECTORY)
      Dir.mkdir(beams)
      [File.join(Generated::OUTPUT, ABI::PackedEmitter::ERLANG_PATH), *ErlangApps.modules(root: root, application: 'erx_f2fs')]
        .each { |source| compile.call(File.join(root, source), output: beams) }
      plan = File.join(directory, F2FS_PLAN)
      arguments = [plan, start, sectors, unit || 'default', version, time, uuid.unpack1('H*')].map(&:to_s)
      runner.run([erl, '-noshell', '-noinput', '-boot', 'no_dot_erlang', '-pa', beams, '-eval', F2FS_EVAL, '-extra', *arguments],
                 name: 'f2fs-format', deadline: 120, chdir: directory, env: Oracle::CLEAN_ERLANG_ENV)
      F2fsVolume.new(start: start, phases: f2fs_phases(File.binread(plan)))
    rescue CommandError => e
      raise Error, "the F2FS format failed:\n#{BoundedFile.read(e.result.fetch('log'), maximum: REPORT_MAX)}"
    end

    # The plan file's blocks by phase, in the order the plan gave them.
    def f2fs_phases(bytes)
      raise Error, 'the F2FS plan is not whole records' unless (bytes.bytesize % F2FS_RECORD).zero?

      records = (0...(bytes.bytesize / F2FS_RECORD)).map do |index|
        phase, address = bytes.unpack('CN', offset: index * F2FS_RECORD)
        [phase, [address, bytes.byteslice((index * F2FS_RECORD) + 5, F2FS_BLOCK)]]
      end
      records.group_by(&:first).sort.map { |_phase, pairs| pairs.map(&:last) }
    end
  end
end
