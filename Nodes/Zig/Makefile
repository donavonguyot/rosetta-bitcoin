ZIG_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := build
ZIG ?= zig
ZIG_ARGS ?=
ZIG_BUILD = $(ZIG) build $(ZIG_ARGS)

.PHONY: build test docs check-toolchain clean
check-toolchain:
	@version=$$($(ZIG) version); \
	if [ "$$version" != "0.16.0" ]; then \
	  echo "error: Zig 0.16.0 required, got $$version; set ZIG=/path/to/zig" >&2; exit 1; \
	fi
build: check-toolchain
	$(ZIG_BUILD)
test: check-toolchain
	$(ZIG_BUILD) test
docs: check-toolchain
	$(ZIG_BUILD) docs
clean:
	rm -rf .zig-cache zig-cache zig-out

# Only the lab integration owns peer topology, campaigns, and Project imports.
ROSETTA ?= $(if $(wildcard $(dir $(ZIG_DIR))/Shared/docker/reference_topology.mk),1,0)
ifeq ($(ROSETTA),1)
include $(ZIG_DIR)/rosetta.mk
endif
