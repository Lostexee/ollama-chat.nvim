# Makefile — Test-Runner für ollama-chat.nvim
#
# Voraussetzungen:
#   - Neovim >= 0.9
#   - plenary.nvim installiert (siehe PLENARY_PATH)
#
# Nutzung:
#   make test                  — alle Tests ausführen
#   make test FILE=sandbox     — nur sandbox_spec.lua
#   make test FILE=executor    — nur executor_spec.lua

NVIM     ?= nvim
# Absoluter Pfad — funktioniert unabhängig vom CWD
ROOT     := $(shell pwd)
INIT     := $(ROOT)/tests/minimal_init.lua
TEST_DIR := $(ROOT)/tests/tools

.PHONY: test test-file

## Alle Tests ausführen (aus dem Repo-Root: make test)
test:
	@cd $(ROOT) && $(NVIM) --headless \
		-u $(INIT) \
		-c "PlenaryBustedDirectory $(TEST_DIR)/ { minimal_init = '$(INIT)' }"

## Einzelne Spec-Datei: make test-file FILE=sandbox
test-file:
	@cd $(ROOT) && $(NVIM) --headless \
		-u $(INIT) \
		-c "PlenaryBustedFile $(TEST_DIR)/$(FILE)_spec.lua"
