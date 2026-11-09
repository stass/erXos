# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bench'
require_relative 'bench_g3'
require_relative 'fiasco'
require_relative 'json_input'
require_relative 'medium_boot'
require_relative 'native_root'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # Gate G5's BeamAsm measurements on the stopgap (docs/plan.md, G5): in ordinary domains
  # the domain service creates, BeamAsm's speedup over the interpreter on the same
  # workload, each flavour's footprint, and the time to load the release when the domain
  # starts. The image is MediumBoot's, whose manifest makes the image carry both runtime
  # images and the domain release; it boots from its single file, without the release
  # medium. At the Erlang shell one line waits for the manifest's configured domain to
  # end, then creates the domains in turn through erx_domain:create, interpreter and
  # BeamAsm alternating, each awaited before the next. Each domain boots in embedded mode,
  # so its start loads every module of its release, runs the workload in its -eval,
  # prints one term with erlang:display and halts. The serial log is the only channel out.
  #
  # The workload is compiled code of the release itself (stdlib's lists, json and erl_scan),
  # the same beam bytes in both flavours: a domain has no connection to load another module
  # through. Building the line, reading the log and the report are pure; the image build
  # and QEMU are the effects at the edge.
  class BenchG5
    # What one run asks, by accelerator: the length of the workload's list, the samples of
    # each workload and the rounds, each one domain of each flavour. TCG is slow, so it gets less.
    Plan = Data.define(:accel, :length, :samples, :rounds, :wait_seconds)
    PLANS = {
      'hvf' => Plan.new(accel: 'hvf', length: 100_000, samples: 5, rounds: 2, wait_seconds: 300),
      'tcg' => Plan.new(accel: 'tcg', length: 10_000, samples: 3, rounds: 1, wait_seconds: 3_600)
    }.freeze
    FLAVOURS = %w[emu jit].freeze
    WORKLOADS = %w[sort json_encode json_decode scan].freeze
    # The fields of a domain's line after {g5, Flavour, in order, then one list of samples
    # per workload, in microseconds:
    # * start_us: from the runtime's start to its -eval, which in embedded mode spans
    #   loading every module of the release (for BeamAsm, translating each) and starting
    #   its applications;
    # * modules, beam_bytes: the modules loaded then whose object code the code path holds,
    #   and that code's size;
    # * prepare_us: erlang:prepare_loading of each of them once more, from the bytes in
    #   memory: decoding, and for BeamAsm translation, without a file read or a purge;
    #   prepare_errors counts the ones refused, and a run with any is not complete;
    # * memory_*: erlang:memory() after the boot.
    SCALARS = %w[start_us modules beam_bytes prepare_us prepare_errors memory_total memory_code memory_system
                 memory_processes].freeze
    SAMPLES = '\[[0-9]+(?:,[0-9]+)*\]'
    # The domain's line: the term erlang:display prints, of integers and the flavour's atom, as
    # a record of the domain's space.
    LINE = /\A#{NativeRoot::DOMAIN_RECORD}\{g5,(?<flavour>emu|jit),(?<scalars>[0-9]+(?:,[0-9]+){#{SCALARS.size - 1}}),
            (?<lists>#{SAMPLES}(?:,#{SAMPLES}){#{WORKLOADS.size - 1}})\}\r*\n?\z/nx
    DONE = /\AG5DONE (?<ends>.*?)\r*\n?\z/n
    # The end of a domain that measured and halted as it should.
    HALTED = /\A\{domain_down,[0-9]+,\{halt,0\}\}\z/

    def initialize(root:, runner: nil, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                   qemu: 'qemu-system-aarch64')
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @compiler = compiler
      @linker = linker
      @qemu = qemu
      @bench = Bench.new(root: @root, runner: @runner)
    end

    # Builds the image, boots it, and writes build/bench/g5-<accel>-*/result.json however
    # far the guest got. The report's 'complete' says whether every domain measured and halted.
    def run(accel:, jobs: 4)
      plan = PLANS.fetch(accel) { raise Error, "no G5 plan for accelerator #{accel}" }
      build = build_record
      manifest = MediumBoot.manifest(File.binread(File.join(@root, ProductionImage::MANIFEST)))
      built, domain = build_image(manifest: manifest, jobs: jobs)
      before = @bench.load_average
      directory = File.join(@root, 'build/qemu', "g5-#{accel}-#{Process.pid}-#{Random.bytes(4).unpack1('H*')}")
      failure = boot(plan: plan, built: built, manifest: manifest, domain: domain, directory: directory)
      guest = guest_result(directory: directory, failure: failure)
      write(self.class.report(plan: plan, guest: guest, build: build, host: @bench.host_description,
                              load: { 'before' => before, 'after' => @bench.load_average }, now: Time.now.utc), accel)
    end

    # The runs of a plan, as [flavour, round], in the order the guest makes them.
    def self.runs(plan) = (1..plan.rounds).flat_map { |round| FLAVOURS.map { |flavour| [flavour, round] } }

    # The shell line: wait for the configured domain's end, then create the plan's domains
    # in turn, each awaited before the next and killed if it outlives the wait, and print
    # G5DONE with each domain's end. A refused create stands in for its end.
    def self.shell_line(plan, domain)
      names = runs(plan).map do |flavour, round|
        "{<<\"g5#{flavour}#{round}\">>,#{flavour == 'jit' ? domain.jit : domain.runtime}}"
      end
      args = domain_args(plan).map { |arg| "\"#{arg}\",0" }.join(',')
      spec = MediumBoot.erlang_map(release: domain.release, release_files: domain.release_files,
                                   memory: MediumBoot::DOMAIN_MEMORY, outer: MediumBoot::DOMAIN_OUTER,
                                   grant: MediumBoot.erlang_map(quota_ns: (1 << 64) - 1, cpuset: 1, capacity_mcpu: 1000),
                                   lane: 4096, args: "<<#{args}>>", env: '<<>>')
      run = "G5Run=fun({Name,Runtime})->case erx_domain:create(#{spec}\#{name=>Name,runtime=>Runtime}) of " \
            "{ok,D}->M=monitor(process,erx_domain:pid(D)),receive {'DOWN',M,process,_,R}->R " \
            "after #{plan.wait_seconds * 1000}->erx_domain:stop(D,kill),timeout end;Refused->Refused end end"
      "G5Wait=#{MediumBoot::DOMAIN_LIB_WAIT},G5Configured=G5Wait(600),#{run}," \
        "io:format(\"G5DONE ~0p~n\",[lists:map(G5Run,[#{names.join(',')}])]).\r"
    end

    # MediumBoot's domain arguments in embedded mode, with the workload as the -eval
    # expression. The library refuses arguments past the boot page's strings, so a
    # workload too long for them is a refused create in the G5DONE line.
    def self.domain_args(plan)
      eval_at = MediumBoot::DOMAIN_ARGS.index('-eval')
      [*MediumBoot::DOMAIN_ARGS[0...eval_at], '-mode', 'embedded', '-eval', workload(plan)].each do |arg|
        raise Error, "a G5 domain argument holds a quote or backslash: #{arg}" if arg.match?(/["\\]/)
      end
    end

    # What each domain evaluates. erl_eval runs it, so each timed sample is one call into
    # the release's compiled code, and the interpreted parts are outside the timed calls.
    def self.workload(plan)
      'T=fun(F)->[element(1,timer:tc(F))||_<-lists:seq(1,' + plan.samples.to_s + ')] end,' \
        'Start=erlang:convert_time_unit(erlang:monotonic_time()-erlang:system_info(start_time),native,microsecond),' \
        'Mem=erlang:memory(),' \
        'Code=[{Mod,Bin}||{Mod,_}<-code:all_loaded(),{_,Bin,_}<-[code:get_object_code(Mod)]],' \
        '{Prepare,Refused}=timer:tc(fun()->length([E||{Mod,Bin}<-Code,' \
        '{error,_}=E<-[erlang:prepare_loading(Mod,Bin)]]) end),' \
        'L=[(X*7919) rem 1000003||X<-lists:seq(1,' + plan.length.to_s + ')],' \
        'J=iolist_to_binary(json:encode(L)),S=binary_to_list(J),' \
        'erlang:display({g5,erlang:system_info(emu_flavor),Start,length(Code),' \
        'lists:sum([byte_size(Bin)||{_,Bin}<-Code]),Prepare,Refused,' \
        'proplists:get_value(total,Mem),proplists:get_value(code,Mem),' \
        'proplists:get_value(system,Mem),proplists:get_value(processes,Mem),' \
        'T(fun()->lists:sort(L) end),T(fun()->json:encode(L) end),' \
        'T(fun()->json:decode(J) end),T(fun()->erl_scan:string(S) end)}),' \
        'erlang:halt(0)'
    end

    # The checkpoints: the production boot to the command shell, the Erlang shell, the
    # line, one domain's line per run and the G5DONE line.
    def self.checkpoints(points:, plan:, domain:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: shell_line(plan, domain)).freeze,
       *runs(plan).each_index.map { |index| { name: "g5-domain-#{index + 1}", pattern: /\A#{NativeRoot::DOMAIN_RECORD}\{g5,/n, seconds: plan.wait_seconds }.freeze },
       { name: 'g5-done', pattern: /\AG5DONE /n, seconds: 600 + plan.wait_seconds }.freeze]
    end

    # The domains' measurements and the G5DONE line's ends from the serial log's text. The
    # ends are guest text, kept as valid UTF-8 for the report.
    def self.read_log(text)
      lines = text.each_line.map(&:b)
      domains = lines.filter_map { |line| LINE.match(line) }.map do |match|
        scalars = SCALARS.zip(match[:scalars].split(',').map { |value| Integer(value, 10) }).to_h
        lists = match[:lists].scan(/\[([0-9,]*)\]/).map { |(body)| body.split(',').map { |value| Integer(value, 10) } }
        { 'flavour' => match[:flavour] }.merge(scalars).merge('samples_us' => WORKLOADS.zip(lists).to_h)
      end
      done = lines.filter_map { |line| DONE.match(line) }.first
      { 'domains' => domains, 'ends' => done && done[:ends].dup.force_encoding(Encoding::UTF_8).scrub('?') }
    end

    # Whether the run measured all it asked: rounds domains of each flavour reported with no
    # refused prepare, and the G5DONE line names one halt with status 0 per run.
    def self.complete?(plan, guest, by)
      ends = guest['ends'].to_s.delete_prefix('[').delete_suffix(']').scan(/\{domain_down,[0-9]+,\{[a-z]+,[0-9]+\}\}|[^,{}]+/)
      by.values.all? { |entries| entries.size == plan.rounds && entries.all? { |entry| entry.fetch('prepare_errors').zero? } } &&
        ends.size == runs(plan).size && ends.all? { |each| HALTED.match?(each) }
    end

    # The report: each workload's median per flavour over every domain of that flavour, and
    # BeamAsm's speedup, the interpreter's median over BeamAsm's; unknown where a side is
    # missing. Pure.
    def self.report(plan:, guest:, build:, host:, load:, now:)
      by = FLAVOURS.to_h { |flavour| [flavour, guest.fetch('domains').select { |entry| entry.fetch('flavour') == flavour }] }
      medians = by.transform_values do |entries|
        next nil if entries.empty?

        WORKLOADS.to_h { |name| [name, median(entries.flat_map { |entry| entry.fetch('samples_us').fetch(name) })] }
          .merge(SCALARS.to_h { |name| [name, median(entries.map { |entry| entry.fetch(name) })] })
      end
      speedup = WORKLOADS.to_h { |name| [name, ratio(medians['emu']&.fetch(name), medians['jit']&.fetch(name))] }
      { 'gate' => 'G5', 'date' => now.strftime('%F'), 'host' => host, 'host_load' => load, 'accel' => plan.accel,
        'plan' => plan.to_h, 'build' => build, 'complete' => complete?(plan, guest, by), 'medians' => medians,
        'speedup' => speedup, 'guest' => guest }
    end

    def self.median(values)
      sorted = values.sort
      return nil if sorted.empty?

      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    # slow over fast, or nil when either is unknown or fast is zero.
    def self.ratio(slow, fast) = slow.nil? || fast.nil? || fast.zero? ? nil : (slow.to_f / fast).round(2)

    private

    # The compiler that builds the image and the ERTS build's flags, as G3's report states them.
    def build_record
      raise Error, 'no compiler is named; G5 needs ERX_CLANG to build and describe the image' if @compiler.empty?

      version = File.read(@runner.run([@compiler, '--version'], name: 'bench-g5-compiler', deadline: 10).fetch('log')).lines.first.to_s.strip
      text = File.read(File.join(@root, BenchG3::CROSS_FILE))
      { 'compiler' => version, 'flags' => BenchG3::FLAG_VARIABLES.to_h { |name| [name, text[/^#{name}="([^"]*)"/, 1]] } }
    end

    def build_image(manifest:, jobs:)
      fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
      fiasco.build(jobs: jobs)
      directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/bench/g5-image'))
      built, _written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                       .build_medium(directory: directory, machine: MediumBoot::MACHINE, manifest_source: manifest)
      [built, MediumBoot.domain_in(built.archive, codec: ABI::Codec.new(ABI::Generator.plan(root: @root).schema))]
    end

    # QEMU's run, returning the error that ended it (or nil) instead of raising it.
    def boot(plan:, built:, manifest:, domain:, directory:)
      watchdog = plan.accel == 'hvf' ? MediumBoot::Run::WATCHDOG : ProductionImage::Run::TCG_WATCHDOG
      points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: watchdog, cpus: 1, manifest_source: manifest,
                                                       memory_mib: MediumBoot::MACHINE.memory_mib)
      Qemu.new(root: @root, runner: @runner, program: @qemu)
          .run(accel: plan.accel, cpus: 1, image: built.single, memory_mib: MediumBoot::MACHINE.memory_mib,
               checkpoints: self.class.checkpoints(points: points, plan: plan, domain: domain),
               command_line: ProductionImage::Run::COMMAND_LINES[plan.accel], directory: directory)
      nil
    rescue Error => error
      error
    end

    # What the guest did: QEMU's report of how the run ended and the serial log's measurements.
    def guest_result(directory:, failure:)
      report_path = File.join(directory, 'report.json')
      qemu = File.file?(report_path) ? JsonInput.parse(File.binread(report_path, 1 << 20), max_bytes: 1 << 20, label: 'QEMU report') : {}
      serial = File.join(directory, 'serial.log')
      text = File.file?(serial) ? File.binread(serial) : ''.b
      { 'state' => qemu.fetch('state', 'failed'), 'error' => failure&.message, 'qemu_version' => qemu['qemu_version'],
        'image_sha256' => qemu['image_sha256'], 'serial_log' => serial, 'qemu_argv' => qemu['argv'] }
        .merge(self.class.read_log(text))
    end

    def write(report, accel)
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      path = File.join(Dir.mktmpdir("g5-#{accel}-", parent), 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      report.merge('report' => path)
    end
  end
end
