# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi'
require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'native_root'
require_relative 'native_runtime'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'release_files'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # Native programs of root's session (docs/design-runtime.md, "Programs as ports";
  # docs/design-programs.md): erx_program:start/1 maps a program from the session's
  # release, runs it in a sub-space the session made, and gives its owner the program's
  # end. The suite's test image is the production image with the three static programs
  # of test/guest/programs/ in the domain release's bin/ (PROGRAMS), each a musl program
  # whose entry, libc_task.c, stops its space with main's return. It keeps the
  # development manifest's session template, so the console logs root in at boot and
  # root's session, root_1, takes the line; it boots without a disk, since nothing here
  # reads /data.
  #
  # At root_1's Erlang shell each case (cases) is one expression, whose answer names it:
  # * exit42 ends by itself and its owner gets {exit_status, 42};
  # * fault loads from the null page, and the fault ends it with ERX_EXIT_SIGNAL plus
  #   SIGSEGV, which erx_prog:status/1 reads as {signaled, sigsegv};
  # * spin runs until port_close/1, which stops its space and reports nothing, since the
  #   port is gone (erx_program_core.c, ERX_PROGRAM_CLOSE): the close answers true, the
  #   port goes down, and no message of it follows;
  # * many runs MANY_RUNS rounds, one after another, each an exit42 that reports 42 and a
  #   spin that port_close/1 ends, each port down before the next program starts. Every
  #   program holds two of the gate worker's 64 registrations (ERX_GATE_SINKS) while it
  #   lives, so a registration either end fails to give back makes a start past the
  #   32nd fail. What else a start makes (budget, group, IRQ object, capability slots)
  #   must be given back too, though 2 * MANY_RUNS programs need not exhaust it.
  # The shell then answers node() again.
  #
  # The programs are file entries, so the backend copies their segments into the space
  # (erx_fiasco_task_image_map_body); a program of image kind, whose code its slice
  # shares, is not run here.
  module Programs
    MACHINE = ProductionImage::DEVELOPMENT_MACHINE
    # Each program by its name in the session's release, domains/erxos/bin/<name>, and the
    # source it is built from.
    PROGRAMS = %w[exit42 fault spin].to_h { |name| [name, "test/guest/programs/#{name}.c"] }.freeze
    PROGRAM_PREFIX = "#{ReleaseFiles::DOMAIN_PREFIX}bin/".freeze
    # How many rounds many runs: more than the 32 programs the gate worker's 64
    # registrations hold at once, for each way a program ends.
    MANY_RUNS = 50
    # How long an expression waits for a program's message or its port's end, in
    # milliseconds.
    WAIT_MS = 10_000
    NODE = "node().\r"
    ROOT_NODE = 'root_1@erxos'

    # A case: what is typed at root_1's Erlang shell, the answer it must print, and how
    # long the answer may take, in seconds.
    Case = Data.define(:name, :expression, :answer, :seconds)

    module_function

    # Typed at the shell as one line: an expression written over several lines here, so
    # it reads as Erlang, then joined with single spaces.
    def line(erlang) = "#{erlang.split.join(' ')}\r"

    # Each case's expression is a fun applied at once, so no case binds a shell variable
    # another sees. A start the driver refused, or an answer other than the one awaited,
    # shows in the case's answer instead of a timeout alone. fault_answer is fault's
    # (Run#fault_answer).
    def cases(fault_answer:)
      [Case.new(name: 'exit42', seconds: 60, answer: '{exit42,42}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(\#{image => <<"bin/exit42">>, pid => 2}),
            receive {P, {exit_status, S}} -> {exit42, S} after #{WAIT_MS} -> {exit42, timeout, P} end
          end)().
       ERLANG
       Case.new(name: 'fault', seconds: 60, answer: fault_answer, expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(\#{image => <<"bin/fault">>, pid => 3}),
            receive {P, {exit_status, S}} -> {fault, S, erx_prog:status(S)} after #{WAIT_MS} -> {fault, timeout, P} end
          end)().
       ERLANG
       # The program runs for half a second first, so the close stops a running program.
       Case.new(name: 'spin', seconds: 60, answer: '{spin,true,down,none}', expression: line(<<~ERLANG)),
         (fun() ->
            case erx_program:start(\#{image => <<"bin/spin">>, pid => 4}) of
              P when is_port(P) ->
                timer:sleep(500),
                R = erlang:monitor(port, P),
                {spin, port_close(P),
                 receive {'DOWN', R, port, P, _} -> down after #{WAIT_MS} -> open end,
                 receive {P, M} -> M after 1000 -> none end};
              Refused -> {spin, Refused}
            end
          end)().
       ERLANG
       # Run(Image, Pid, End) starts a program, lets End see its port, and waits for the
       # port's end: ok, or what went wrong instead.
       Case.new(name: 'many', seconds: 300, answer: "{many,#{MANY_RUNS}}", expression: line(<<~ERLANG))
         (fun() ->
            Run = fun(Image, Pid, End) ->
                case erx_program:start(\#{image => Image, pid => Pid}) of
                  P when is_port(P) ->
                    R = erlang:monitor(port, P),
                    case End(P) of
                      ok -> receive {'DOWN', R, port, P, _} -> ok after #{WAIT_MS} -> {open, Image} end;
                      Other -> Other
                    end;
                  Refused -> {Image, Refused}
                end
              end,
            Exit = fun(P) -> receive {P, {exit_status, 42}} -> ok; {P, Status} -> Status after #{WAIT_MS} -> timeout end end,
            Close = fun(P) -> true = port_close(P), ok end,
            Many = fun Loop(Done) when Done =:= #{MANY_RUNS} -> {many, Done};
                       Loop(Done) ->
                         case {Run(<<"bin/exit42">>, 10, Exit), Run(<<"bin/spin">>, 11, Close)} of
                           {ok, ok} -> Loop(Done + 1);
                           Failed -> {many, Done, Failed}
                         end
                   end,
            Many(0)
          end)().
       ERLANG
      ].freeze
    end

    # The production checkpoints of a test image's boot to the system's command shell,
    # then root_1's command shell and Erlang shell, and each case: typed once the shell
    # has answered node(), its answer, then node() typed again. An answer line of the
    # case's own, or an exception, ends the cell at once, quoting the line, unless it is
    # the answer.
    def checkpoints(points, fault_answer:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      node = ->(name) { { name: name, pattern: SessionDomain.answer(ROOT_NODE), seconds: 60 } }
      typed = cases(fault_answer: fault_answer).flat_map do |each|
        [node.call("#{each.name}-ready").merge(type: each.expression).freeze, answer_point(each)]
      end
      [*points,
       SessionDomain.session_shell('root_1-shell', ProductionImage::Run::ERL_LINE),
       ProductionImage::Run::ERLANG_SHELL.merge(name: 'root_1-erlang-shell', type: NODE).freeze,
       *typed, node.call('last-node').freeze].freeze
    end

    def answer_point(each)
      expected = SessionDomain.answer(each.answer)
      { name: each.name, pattern: /\A#{SessionDomain::PROMPT}(?:\{#{each.name},|\*\* exception)/n, seconds: each.seconds,
        type: NODE,
        verify: ->(text) { raise Error, "the #{each.name} case answers #{text.inspect}" unless expected.match?(text) } }.freeze
    end

    # Builds the programs and the test image once, then boots it under HVF at each CPU
    # count, where placement puts each cell. Returns { "<accel>-<n>cpu" => 'passed' }; any
    # disagreement raises.
    class Run
      def self.cells(cpus) = cpus.map { |count| QemuCells::Cell.new(accel: QemuCells::LOCAL_ACCELERATOR, cpus: count).name }

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @manifest = File.binread(File.join(@root, ProductionImage::MANIFEST))
        @build = File.join(@root, 'build/programs')
        @schema = ABI::Generator.plan(root: @root).schema
        @codec = ABI::Codec.new(@schema)
      end

      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", boot(accel, count, remote, built)]
        end
      end

      private

      # The production image with PROGRAMS added to the domain release, under the
      # development manifest, session template and all.
      def image(fiasco)
        runtime = NativeRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@build, 'image'))
        # The image's build builds the runtime again; make finds nothing left to do.
        libc = runtime.build.libc
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco, runtime: runtime)
                       .build_test_image(directory: directory, added: added(fiasco, libc: libc),
                                         machine: MACHINE, manifest_source: @manifest)
      end

      # Each program linked over musl's libc.a, the one the runtime images link, as a
      # release file of the session's: no system mark, since only the system release's
      # files carry it.
      def added(fiasco, libc:)
        native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
        programs = PROGRAMS.map do |name, source|
          [name, native.build_task_receipted(name: name, sources: [*NativeRoot::LIBC_TASK, source], directory: File.join(@build, name),
                                             archives: [libc, fiasco.user_library('libgcc.a')])]
        end
        entries = programs.map do |name, program|
          { 'path' => "#{PROGRAM_PREFIX}#{name}", 'kind' => @codec.member('entry_kind', 'file'), 'flags' => 0, 'id' => "program-#{name}",
            'artifact' => program.fetch(:program), 'receipt' => program.fetch(:receipt) }.freeze
        end
        ProductionImage::Added.new(entries: entries.freeze, inputs: programs.flat_map { |_, program| program.fetch(:inputs) }.uniq.freeze,
                                   imports: {}.freeze)
      end

      def boot(accel, count, remote, built)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: MACHINE.memory_mib, test_image: true)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MACHINE.memory_mib,
                 checkpoints: Programs.checkpoints(points, fault_answer: fault_answer))
        'passed'
      end

      # fault's answer as the shell prints it: the status, ERX_EXIT_SIGNAL plus the signal the
      # ABI file's fault table gives a memory fault (a load from the null page), and that
      # signal's reading by erx_prog:status/1.
      def fault_answer
        row = @schema.faults.find { |each| each.kind == 'memory' }
        raise Error, 'the fault table has no memory row' if row.nil?

        "{fault,#{@codec.member('exit_kind', 'signal') + row.signal.number},{signaled,sig#{row.signal.name}}}"
      end
    end
  end
end
