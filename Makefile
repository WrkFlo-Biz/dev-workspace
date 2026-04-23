.DEFAULT_GOAL := help
REPO := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(REPO)scripts
PROJECTS := $(sort $(wildcard $(HOME)/projects/*))

.PHONY: help deploy health check sessions pull status install

help:
	@printf '%s\n' \
		'Targets:' \
		'  deploy   Run dws-update.sh --force' \
		'  health   Run dws-health.sh' \
		'  check    Alias for health' \
		'  sessions Run dws-sessions.sh list' \
		'  pull     Git pull all projects in ~/projects' \
		'  status   Git status all projects in ~/projects' \
		'  install  Run vm-setup.sh' \
		'  help     Show this help'

deploy:
	@"$(SCRIPTS)/dws-update.sh" --force

health:
	@"$(SCRIPTS)/dws-health.sh"

check: health

sessions:
	@"$(SCRIPTS)/dws-sessions.sh" list

pull:
	@for dir in $(PROJECTS); do \
		printf '\n[%s]\n' "$$dir"; \
		git -C "$$dir" pull || exit $$?; \
	done

status:
	@for dir in $(PROJECTS); do \
		printf '\n[%s]\n' "$$dir"; \
		git -C "$$dir" status --short --branch || exit $$?; \
	done

install:
	@"$(SCRIPTS)/vm-setup.sh"
