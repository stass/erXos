# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

RUBY ?= ruby
# Empty: HVF when the host offers it, else TCG.
ACCEL ?=
JOBS ?= 4
# The platform `make pack` builds for.
PLATFORM ?= qemu-virt
FLAVOUR ?= emu
DOCKER_CONTEXT ?=

.DEFAULT_GOAL := all

.PHONY: all build run check check-sources status setup fetch check-tla check-cbmc check-litmus check-rc-oracle check-arch-terms
.PHONY: oracle-bootstrap oracle-build check-oracle check-oracle-host check-oracle-hosted bench
.PHONY: generate web pack
.PHONY: check-reproducible check-fuzz check-sanitizers check-asan check-ubsan check-tsan
.PHONY: check-runtime-seam check-runtime-hosted
.PHONY: check-stack-proof check-conformance check-debug-log check-qemu check-qemu-mutant check-native-seeds check-boot-image

all: build

build:
	$(RUBY) tools/erx build fiasco --jobs $(JOBS)

run: build
	$(RUBY) tools/erx qemu $(if $(ACCEL),--accel $(ACCEL))

check:
	$(RUBY) tools/erx check

generate:
	$(RUBY) tools/erx generate

# The web client into build/web/, offline from the packages `make fetch` installed
# (docs/design-web.md, "Build and dependencies"). `make check` runs it too.
web:
	$(RUBY) tools/erx build web

# The production image and its medium for PLATFORM into build/production-image/PLATFORM/:
# QEMU's release medium, or for raspi4b the SD card's boot/ and sdcard.img.
pack:
	$(RUBY) tools/erx pack --medium --platform $(PLATFORM)

# Every platform's image and medium: QEMU's release medium and the Raspberry Pi 4's SD card.
check-reproducible:
	$(RUBY) tools/erx check-reproducible --platform qemu-virt
	$(RUBY) tools/erx check-reproducible --platform raspi4b

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
# tools/lib/erx/qemu_suites/, under HVF; TCG runs only the production image's
# deterministic transcript and a one-CPU boot smoke. A host whose QEMU lacks
# HVF or TCG fails the gate. It runs every boot fresh and every cell on this
# host, one after another; `tools/erx check-qemu` without --fresh reuses boots that passed on the
# same inputs, and with --remote may move cells to a second host
# (docs/design-build.md, "Placing cells").
check-qemu:
	$(RUBY) tools/erx check-qemu --fresh --one-at-a-time --jobs $(JOBS)

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
	$(RUBY) test/integration/runtime_literal_token_test.rb
	$(RUBY) tools/erx check-runtime-seam

check-conformance:
	$(RUBY) tools/erx conformance

check-debug-log:
	$(RUBY) tools/erx check-debug-log

check-boot-image:
	$(RUBY) tools/erx check-boot-image
	$(RUBY) test/integration/domain_image_test.rb

status:
	$(RUBY) tools/erx status

setup:
	$(RUBY) tools/erx setup --jobs $(JOBS)

fetch:
	$(RUBY) tools/erx fetch $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",)

check-tla:
	$(RUBY) tools/erx check-tla

check-cbmc:
	$(RUBY) tools/erx check-cbmc

# Builds herd7 from the fetched herdtools7 pin first when it is missing or stale
# (tools/erx build herd7); needs OCaml, dune, menhir and zarith from Homebrew.
check-litmus:
	$(RUBY) tools/erx check-litmus

# The command shell's oracle: needs plan9port fetched (tools/erx fetch --source plan9port);
# the evaluator's corpus against it needs stock OTP built (make oracle-bootstrap).
check-rc-oracle:
	$(RUBY) tools/erx build rc-oracle
	$(RUBY) test/integration/rc_oracle_test.rb
	ERX_ERL=$(CURDIR)/build/oracle/jit/install/bin/erl ERX_ERLC=$(CURDIR)/build/oracle/jit/install/bin/erlc \
		$(RUBY) test/integration/erx_shell_corpus_test.rb

check-arch-terms:
	$(RUBY) tools/erx check-arch-terms

check-stack-proof:
	$(RUBY) tools/erx check-stack-proof

oracle-bootstrap:
	$(RUBY) tools/erx oracle build --backend native --flavour jit --jobs $(JOBS)

oracle-build:
	$(RUBY) tools/erx oracle build $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)

check-oracle:
	$(RUBY) tools/erx check-oracle

# OTP's suites for /tmp on the hosted runtime and on stock OTP, compared
# case by case (tools/erx oracle hosted); the fast route of check-oracle.
# The reporter's own tests run first, on stock OTP (make oracle-bootstrap),
# then its log tree's, on both.
check-oracle-hosted:
	ERX_ERL=$(CURDIR)/build/oracle/jit/install/bin/erl ERX_ERLC=$(CURDIR)/build/oracle/jit/install/bin/erlc \
		$(RUBY) test/integration/oracle_reporter_test.rb
	ERX_ERL=$(CURDIR)/build/oracle/jit/install/bin/erl ERX_ERLC=$(CURDIR)/build/oracle/jit/install/bin/erlc \
		$(RUBY) test/integration/oracle_ct_oracle_test.rb
	$(RUBY) test/integration/oracle_log_tree_test.rb
	$(RUBY) tools/erx oracle hosted

check-oracle-host:
	$(RUBY) tools/erx oracle run emulator $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)
	$(RUBY) tools/erx oracle run kernel $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)
	$(RUBY) tools/erx oracle run stdlib $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)

bench:
	$(RUBY) tools/erx bench otp-pingpong --flavour $(FLAVOUR)
	$(RUBY) tools/erx bench otp-spawn --flavour $(FLAVOUR)
