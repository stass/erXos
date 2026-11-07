# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'socket'
require_relative 'code_load'
require_relative 'error'
require_relative 'etf'
require_relative 'hostlink_client'

module Erx
  # Two of M4's exit criteria against a booted guest with four CPUs, through its host link
  # (docs/plan.md, M4): "a module reloaded in a loop on four CPUs never runs stale code" and
  # "a blob one bit off its hash never loads".
  #
  # The guest's half is test/fixtures/hostlink/erx_reload_probe.erl, whose module doc says
  # what stale means and how it is observed. The host installs it, with the first version
  # of erx_reload_subject, through the install facet as `tools/erx load` does (CodeLoad);
  # the kernel command line's -eval (START) starts the probe once it is loaded. The host
  # then loads each further version, one at a time, and reads the probe's verdict from the
  # console's transcript. Between the first load and the loop it sends the next version
  # with one bit flipped and checks that the store refuses it, still lacks it, refuses a
  # load naming it, and that the module's history is unchanged.
  module ReloadGuest
    SECONDS = 300
    SUBJECT = 'erx_reload_subject'
    SYSTEM_DOMAIN = 4
    # The versions of the subject a run loads: the first and the probe's 32 reloads.
    VERSIONS = 33
    PROBE_SOURCE = 'test/fixtures/hostlink/erx_reload_probe.erl'
    # The -eval expression the guest boots with: one word, without spaces or quotes, as the
    # kernel command line carries it, waiting for the probe's module to be installed.
    START = 'spawn(fun()->(try(lists:foreach(fun(_)->(case(code:is_loaded(erx_reload_probe))of(false)->' \
            'timer:sleep(100);_->throw(run)end)end,lists:seq(1,3000)))catch(run)->erx_reload_probe:run()end)' \
            'end).'
    READY = /reload-probe ready schedulers (\d+) loads (\d+)/
    DONE = /reload-probe done committed (\d+) stale (\d+) behind (\d+) calls ([\d,]+) straddled (\d+) killed (\d+) tags ([\d,]+)/
    FAILED = /reload-probe failed[^\r\n]*/

    OK = Etf::Atom.new(name: 'ok')
    ERROR = Etf::Atom.new(name: 'error')

    # The modules a run loads: the probe and each version of the subject, oldest first.
    Modules = Data.define(:probe, :subjects)

    module_function

    # The version whose module is larger than one piece, so its upload, refused and whole,
    # takes more than one put; its bytes are random, so the literal chunk's compression
    # keeps them.
    PADDED = 2
    PAD_BYTES = 80_000

    # The subject's source whose tag/0 returns version, padded for PADDED.
    def subject_source(version)
      return "-module(#{SUBJECT}).\n-export([tag/0]).\ntag() -> #{version}.\n" unless version == PADDED

      "-module(#{SUBJECT}).\n-export([tag/0, pad/0]).\ntag() -> #{version}.\n" \
        "pad() -> <<#{Random.new(version).bytes(PAD_BYTES).bytes.join(',')}>>.\n"
    end

    # Compiles the probe and versions versions of the subject under directory with compile,
    # an ErlangCompile, and returns their Modules. directory is empty.
    def compile(compile:, root:, directory:, versions:)
      probe_directory = File.join(directory, 'probe')
      FileUtils.mkdir_p(probe_directory)
      probe = compile.call(File.join(root, PROBE_SOURCE), output: probe_directory)
      subjects = (1..versions).map do |version|
        output = File.join(directory, "v#{version}")
        FileUtils.mkdir_p(output)
        source = File.join(output, "#{SUBJECT}.erl")
        File.write(source, subject_source(version))
        CodeLoad::Blob.from_file(compile.call(source, output: output))
      end
      Modules.new(probe: CodeLoad::Blob.from_file(probe), subjects: subjects)
    end

    # Runs both checks over the host link at socket; serial is the guest's console
    # transcript, cpus the CPUs it booted with. Returns what the probe reported.
    def call(socket, build:, modules:, serial:, cpus:)
      UNIXSocket.open(socket) do |io|
        client = HostlinkClient.new(io: io, expected_build: build)
        client.hello
        facet = CodeLoad.open_install(client)
        first, *rest = modules.subjects
        loaded = CodeLoad.install(client, facet: facet, blobs: [modules.probe, first])
        check(loaded.sent.size == 2, 'the first load sends both modules', loaded.sent)
        ready(wait_for(serial, READY), cpus: cpus, loads: rest.size)
        only_missing(client, facet, [modules.probe, first, rest.first])
        one_bit_off(client, facet, rest.first)
        rest.each do |subject|
          result = CodeLoad.install(client, facet: facet, blobs: [subject])
          check(result.sent == [SUBJECT], 'a reload sends its one new blob', result.sent)
        end
        verdict(wait_for(serial, DONE), cpus: cpus, loads: rest.size)
      end
    end

    def ready(match, cpus:, loads:)
      check(match[1].to_i == cpus, "the probe runs a worker on each of #{cpus} schedulers", match[0])
      check(match[2].to_i == loads, "the probe waits for #{loads} loads", match[0])
    end

    # The store, asked about blobs, lacks exactly the last, which was never sent.
    def only_missing(client, facet, blobs)
      reply = client.call(CodeLoad.missing_request(blobs), target: facet)
      check(reply == Etf::Tuple.new(elements: [OK, [blobs.last.sha256]]), 'the store lacks only the unsent blob', reply)
    end

    # The bytes of blob with one bit flipped, sent in pieces under blob's hash, are refused when the
    # blob is complete; the store still lacks the hash, a load naming it is refused as
    # missing, and the subject's history is what it was.
    def one_bit_off(client, facet, blob)
      before = history(client, facet)
      bytes = blob.bytes.dup
      middle = bytes.bytesize / 2
      bytes.setbyte(middle, bytes.getbyte(middle) ^ 0x01)
      flipped = CodeLoad::Blob.new(name: blob.name, sha256: blob.sha256, bytes: bytes)
      check(CodeLoad.pieces(flipped).size > 1, 'the refused blob takes more than one piece', blob.name)
      replies = CodeLoad.pieces(flipped).map do |offset, piece|
        [offset + piece.bytesize, client.call(CodeLoad.put_request(flipped, offset, piece), target: facet)]
      end
      *taken, (_, refusal) = replies
      taken.each do |ends, reply|
        check(reply == Etf::Tuple.new(elements: [OK, Etf::Tuple.new(elements: [Etf::Atom.new(name: 'next'), ends])]),
              'a piece of the blob one bit off', reply)
      end
      check(refusal == error(Etf::Atom.new(name: 'hash_mismatch')), 'a blob one bit off its hash', refusal)
      reply = client.call(CodeLoad.missing_request([blob]), target: facet)
      check(reply == Etf::Tuple.new(elements: [OK, [blob.sha256]]), 'the refused blob is still missing', reply)
      reply = client.call(CodeLoad.load_request([blob]), target: facet)
      check(reply == error(Etf::Tuple.new(elements: [Etf::Atom.new(name: 'missing'), [blob.sha256]])),
            'a load naming the refused blob', reply)
      after = history(client, facet)
      check(after == before, "the subject's history after the refused blob", after)
    end

    def history(client, facet)
      client.call(Etf::Tuple.new(elements: [Etf::Atom.new(name: 'history'), SYSTEM_DOMAIN, SUBJECT.b]),
                  target: facet)
    end

    # The probe saw every load, no stale call, and every worker calling across reloads.
    def verdict(match, cpus:, loads:)
      committed, stale, behind, calls, straddled, killed, tags = match.captures
      calls = calls.split(',').map(&:to_i)
      tags = tags.split(',').map(&:to_i)
      check(committed.to_i == loads + 1, "the probe saw #{loads + 1} loads", match[0])
      check(stale.to_i.zero?, 'no call ran a version older than the last committed load', match[0])
      check(behind.to_i.zero?, 'no call ran a version older than one already run', match[0])
      check(calls.size == cpus && calls.all?(&:positive?), 'every worker called the subject', match[0])
      check(tags.all? { |seen| seen >= 2 }, 'every worker called across reloads', match[0])
      { committed: committed.to_i, calls: calls.sum, straddled: straddled.to_i, killed: killed.to_i, tags: tags }
    end

    # The first match of pattern in the transcript at serial, waiting up to SECONDS; a
    # failed line of the probe ends the wait. The transcript is the guest's, so what is
    # quoted from it in an error goes through the line escape.
    def wait_for(serial, pattern, seconds: SECONDS)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        text = File.file?(serial) ? File.binread(serial) : ''
        match = pattern.match(text)
        return match if match

        failed = FAILED.match(text)
        raise Error, "reload probe: #{LineEscape.escape(failed[0])}" if failed
        raise Error, "reload probe: no line matching #{pattern.source} within #{seconds} s" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= limit

        sleep(0.2)
      end
    end

    def error(reason) = Etf::Tuple.new(elements: [ERROR, reason])

    def check(holds, what, seen)
      shown = seen.is_a?(String) ? LineEscape.escape(seen) : HostlinkClient.show(seen)
      raise Error, "reload check: #{what}: saw #{shown}" unless holds
    end
  end
end
