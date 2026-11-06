# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

RUBY ?= ruby
ACCEL ?= tcg
JOBS ?= 4
FLAVOUR ?= emu
DOCKER_CONTEXT ?=

.DEFAULT_GOAL := all

.PHONY: all build run check check-sources status setup fetch check-tla check-hw generate-hw check-arch-terms
.PHONY: check-sysreg generate-sysreg oracle-bootstrap oracle-build check-oracle check-oracle-host check-oracle-hosted bench
.PHONY: check-generated check-abi generate-abi check-terminal generate-terminal
.PHONY: check-reproducible check-fuzz check-sanitizers check-asan check-ubsan check-tsan
.PHONY: check-runtime-seam check-runtime-hosted
.PHONY: check-stack-proof check-conformance check-debug-log check-qemu check-qemu-mutant check-native-seeds check-boot-image

all: build

build:
	$(RUBY) tools/erx build fiasco --jobs $(JOBS)

run: build
	$(RUBY) tools/erx qemu --accel $(ACCEL)

check:
	$(RUBY) tools/erx check

check-generated:
	$(RUBY) tools/erx check-generated

check-reproducible:
	$(RUBY) tools/erx check-reproducible

check-fuzz:
	$(RUBY) tools/erx check-fuzz

check-sanitizers:
	$(RUBY) tools/erx check-sanitizers

check-asan check-tsan: check-sanitizers

check-ubsan:
	$(RUBY) tools/erx check-ubsan

check-sources:
	$(RUBY) tools/erx check-sources

# Every kernel-touching change runs this: all QEMU suites, discovered from
# tools/lib/erx/qemu_suites/, over tcg and hvf. A missing accelerator is
# reported as not run and fails the gate; pass ACCEL_LIST=tcg to narrow it.
ACCEL_LIST ?= tcg,hvf
check-qemu:
	$(RUBY) tools/erx check-qemu --accel $(ACCEL_LIST) --jobs $(JOBS)

# Seeds a failure into a copy of the sources and checks the gate reports it.
check-qemu-mutant:
	$(RUBY) test/integration/qemu_gate_mutant_test.rb

# Each seeded failure of the threads and watchdog suites, seen to fail.
check-native-seeds:
	$(RUBY) test/integration/native_seeds_test.rb

# ERTS's imports against sys/erxos/imports.txt, on the built hosted runtime. It
# fails when the runtime is not built or is older than the tree.
check-runtime-seam:
	$(RUBY) tools/erx check-runtime-seam

# Builds the hosted runtime and drives a terminal to `1>`. The dialogue has a budget
# of 60 s; the build takes minutes. `make check` builds no runtime and runs neither.
check-runtime-hosted:
	$(RUBY) tools/erx build runtime --jobs $(JOBS)
	$(RUBY) test/integration/runtime_event_test.rb
	$(RUBY) test/integration/runtime_device_test.rb
	$(RUBY) test/integration/runtime_hosted_smoke_test.rb
	$(RUBY) test/integration/runtime_console_test.rb
	$(RUBY) test/integration/runtime_prim_file_test.rb
	$(RUBY) test/integration/runtime_release_test.rb
	$(RUBY) tools/erx check-runtime-seam

check-conformance:
	$(RUBY) tools/erx conformance

check-debug-log:
	$(RUBY) tools/erx check-debug-log

check-boot-image:
	$(RUBY) tools/erx check-boot-image

status:
	$(RUBY) tools/erx status

setup:
	$(RUBY) tools/erx setup --jobs $(JOBS)

fetch:
	$(RUBY) tools/erx fetch $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",)

check-tla:
	$(RUBY) tools/erx check-tla

check-hw:
	$(RUBY) tools/gen_hw.rb --check

generate-hw:
	$(RUBY) tools/gen_hw.rb

check-abi:
	$(RUBY) tools/gen_abi.rb --check

generate-abi:
	$(RUBY) tools/gen_abi.rb

check-terminal:
	$(RUBY) tools/gen_terminal.rb --check

generate-terminal:
	$(RUBY) tools/gen_terminal.rb

check-arch-terms:
	$(RUBY) tools/erx check-arch-terms

check-stack-proof:
	$(RUBY) tools/erx check-stack-proof

check-sysreg:
	$(RUBY) tools/sysreg_extract.rb --check

generate-sysreg:
	$(RUBY) tools/sysreg_extract.rb

oracle-bootstrap:
	$(RUBY) tools/erx oracle build --backend native --flavour jit --jobs $(JOBS)

oracle-build:
	$(RUBY) tools/erx oracle build $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)

check-oracle:
	$(RUBY) tools/erx check-oracle

# OTP's suites for /tmp on the hosted runtime and on stock OTP, compared
# case by case (tools/erx oracle hosted); the fast route of check-oracle.
check-oracle-hosted:
	$(RUBY) tools/erx oracle hosted

check-oracle-host:
	$(RUBY) tools/erx oracle run emulator $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)
	$(RUBY) tools/erx oracle run kernel $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)
	$(RUBY) tools/erx oracle run stdlib $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)

bench:
	$(RUBY) tools/erx bench otp-pingpong --flavour $(FLAVOUR)
	$(RUBY) tools/erx bench otp-spawn --flavour $(FLAVOUR)
