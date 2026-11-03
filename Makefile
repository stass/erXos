# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

RUBY ?= ruby
ACCEL ?= tcg
JOBS ?= 4
FLAVOUR ?= emu
DOCKER_CONTEXT ?=

.DEFAULT_GOAL := all

.PHONY: all build run check check-sources status fetch check-tla check-hw generate-hw check-arch-terms
.PHONY: check-sysreg generate-sysreg oracle-bootstrap oracle-build check-oracle check-oracle-host bench
.PHONY: check-generated check-abi generate-abi check-terminal generate-terminal
.PHONY: check-reproducible check-fuzz check-sanitizers check-asan check-ubsan check-tsan

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

status:
	$(RUBY) tools/erx status

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

check-oracle-host:
	$(RUBY) tools/erx oracle run emulator $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)
	$(RUBY) tools/erx oracle run kernel $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)
	$(RUBY) tools/erx oracle run stdlib $(if $(strip $(DOCKER_CONTEXT)),--docker-context "$(DOCKER_CONTEXT)",) --flavour $(FLAVOUR) --jobs $(JOBS)

bench:
	$(RUBY) tools/erx bench otp-pingpong --flavour $(FLAVOUR)
	$(RUBY) tools/erx bench otp-spawn --flavour $(FLAVOUR)
