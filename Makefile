SHELL := /bin/bash
.DEFAULT_GOAL := help

CONFIG ?= setup.local.conf
MODE ?=
SERVER ?=
SERVERS ?= $(SERVER)
export SETUP_CONFIG := $(CONFIG)
export SETUP_MODE := $(MODE)
export SETUP_SERVERS := $(SERVERS)

.PHONY: setup plan help
setup plan:
	@args=(--config "$$SETUP_CONFIG" --mode "$$SETUP_MODE"); \
	read -r -a servers <<< "$$SETUP_SERVERS"; \
	for server in "$${servers[@]}"; do args+=(--server "$$server"); done; \
	if [[ "$@" = plan ]]; then args+=(--plan); fi; \
	./setup.sh "$${args[@]}"

help:
	@echo 'make plan MODE=first SERVER=isu1:s1 [CONFIG=setup.local.conf]'
	@echo 'make setup MODE=first SERVER=isu1:s1 [CONFIG=setup.local.conf]'
	@echo 'make setup MODE=join SERVERS="isu2:s2 isu3:s3" [CONFIG=setup.local.conf]'
