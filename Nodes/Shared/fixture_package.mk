# Shared fixture consumption; callers inherit one resolved extraction path.
include ../Shared/state_root.mk
RB_FIXTURE_SHARED := $(abspath build/fixture-package)
export RB_FIXTURE_SHARED
.PHONY: fixture-package
fixture-package:
	python3 ../../Project/scripts/build_fixture_package.py --unpack "$(RB_FIXTURE_SHARED)"
