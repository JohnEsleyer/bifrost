# =============================================================================
#  BIFROST - Makefile
# =============================================================================

SHELL := /bin/bash
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: help install uninstall test doctor check lint

help:
	@echo "bifrost - agent bridge to your VPS"
	@echo
	@echo "  make install     install the CLI + write the ~/.ssh/config block"
	@echo "  make uninstall   remove the CLI + the managed ssh config block"
	@echo "  make test        run the hermetic test suite"
	@echo "  make doctor      run bifrost doctor"
	@echo "  make check       bash -n syntax check on every script"

install:
	@./install.sh

uninstall:
	@./uninstall.sh

test:
	@./tests/test_bifrost.sh

doctor:
	@./bin/bifrost doctor

check:
	@for f in bin/bifrost install.sh uninstall.sh tests/test_bifrost.sh; do \
		bash -n "$$f" && echo "  ok  $$f" || exit 1; \
	done

lint: check
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning bin/bifrost install.sh uninstall.sh || \
		echo "  (shellcheck not installed - skipped)"
