# erXos overview

erXos is an operating system built around Erlang: a machine where
applications, system services and drivers share one way of communicating,
handling failure and understanding what is running.

The idea is to bring together two things that are often separate: a live
programming environment you can explore and change while it runs, and an
operating system with hardware protection and explicit limits on what
each part may do.

Imagine following a request from an application into a file service,
seeing which processes are involved and which code they are executing,
then updating a service without shutting down the machine. If a driver
crashes, its supervisor can restart it. If an application misbehaves,
its memory boundary and resource limits contain it. Those are the kinds
of everyday experiences the design aims to make possible.

This document introduces the target design. The [architecture](design.md)
defines its contracts, and the [roadmap](plan.md) sets out how to build
and test it.

## Why build an operating system around Erlang?

Erlang is a programming language and runtime designed for concurrent,
long-running systems. Its applications consist of many small processes
that communicate by sending messages. These are lightweight runtime
processes: creating one does not require creating a separate operating
system process.

Failure is part of that model. A process can monitor another process and
learn when it dies. A supervisor is a process responsible for restarting
the parts it looks after. Code can also be replaced while the system is
running. Together, these ideas give developers a practical way to build
systems that keep working as individual parts fail or change.

erXos carries that model through the machine. A file service or a driver
is something you can message, inspect and supervise, just as you would
an application component. The same tools can explain both application
behaviour and the services beneath it.

The value is continuity: fewer different models to learn, and more of
the system visible from the environment in which you program it.

## One process world, with walls where they matter

Lightweight Erlang processes give applications structure, but they do
not provide hardware isolation from a faulty runtime or native code.
erXos adds that protection through **domains**.

A domain is a protected group of processes with its own runtime, memory
and resource limits. Applications and services can live in separate
domains while still using Erlang messages, monitoring and supervision
across the boundaries. Each receiving runtime checks which outside
processes are allowed to contact its processes.

Underneath is a small **capability microkernel** written in C. It
enforces memory protection, allocates CPU time and controls access to
kernel objects and devices. A capability is an explicit right to use a
particular resource. Knowing a name or guessing an identifier does not
grant that right.

The kernel gives each runtime a bounded share of CPU time; the runtime
decides which of its lightweight processes to run within that share.
Memory has explicit budgets too. This preserves inexpensive process
creation and switching while giving the machine one authority over
resources.

Every runtime runs with restricted hardware access, including the one
hosting the trusted system services. Only the kernel runs with full
hardware privileges. Erlang services decide who should receive resources;
the kernel enforces the resulting boundaries.

## A machine you can understand while it runs

Inspection is part of the design from the beginning. The console and
development tools share a view of processes, domains, native programs
and kernel objects. You can connect activity to source code and see
kernel scheduling and Erlang scheduling on the same timeline.

That matters when a system is slow or failing. You need to know whether
a process is waiting for a reply, a service has exhausted its CPU share,
or a domain has disappeared. Keeping those events in one view helps you
follow the cause across layers.

The tools also preserve uncertainty: an unanswered query is shown as a
timeout, and unavailable information stays unknown. Inspection itself
is subject to permissions.

Development follows the same live model. Compile on the host, upload
code to the machine, inspect the result and keep working. Live updates
and supervision make change part of normal operation, though replacing
code still requires care with application state.

## Familiar tools in a different foundation

Erlang is the main language for system services, file systems, the
network stack and drivers. Thin C shims handle device access and work
such as checksums and bulk copies where per-byte performance matters.
This brings more system behaviour into the same inspectable,
supervised environment as applications.

Native programs have a place too. A UNIX-compatible programming interface
using the musl C library supports recompiled UNIX software, with the
available interface growing in stages. Each program runs in a protected
space under its session,
with the authority its starter supplies. The goal is useful UNIX
software alongside Erlang, with compatibility tested and differences
documented.

Files retain familiar paths, but each domain has its own view of the
file tree, containing only the file services and rights it was given.
The command shell combines Erlang commands and native programs;
Erlang pipelines can carry structured records, preserving information
that plain text would lose.

## Why this combination matters

erXos explores whether a whole computer can be easier to reason about
when its programming model, failure model and inspection tools agree.
Supervision becomes useful below the application layer. Hardware
boundaries limit the reach of failures. Explicit permissions and
resource budgets make dependencies easier to see and constrain.

The influences fit that goal: Erlang/OTP supplies processes and
supervision; L4/Fiasco supplies the microkernel lineage; Plan 9 and
Inferno inform private file namespaces and a runtime-centred environment;
Genera inspires a machine that remains open to inspection and change.

These choices have costs. A runtime per domain uses memory. Shared
services can become bottlenecks. The trusted system domain is a critical
dependency whose failure resets the machine. Device isolation depends
on hardware support, and resource limits do not eliminate timing side
channels. The design treats these as constraints to test and account for.

## Getting to a working machine

erXos is meant to run on more than one architecture and platform. The
first target is 64-bit Arm, initially in the QEMU emulator and then on
the Raspberry Pi 4 and 5; other architectures and platforms follow as
ports behind the same kernel interface. Development starts on Apple Silicon macOS,
with Linux also supported as a host.

The build path uses established components to reach a usable system:
Erlang/OTP, musl and a near-stock Fiasco kernel. Fiasco serves as a
stopgap behind erXos's own kernel interface, and the first phase brings
the system up on it without security or scheduling guarantees; erXos's
C kernel replaces it after running the same system and passing the
conformance tests.
Development builds run trusted code only until the security closure
milestone on erXos's own kernel.

The roadmap grows through demonstrations: a booting shell, live
inspection, protected domains, native programs, persistent files and
supervised drivers. Behaviour is checked against stock Erlang/OTP and
independent reference implementations, with performance measured rather
than inferred from the design.

For the next level of detail, read the [architecture](design.md). For
the sequence of working demonstrations and their acceptance criteria,
read the [roadmap](plan.md).
