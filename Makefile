PROJECTS := tokens hooks add-ons
PROJECT ?=

ifneq ($(strip $(PROJECT)),)
ifneq ($(words $(PROJECT)),1)
$(error PROJECT must name one project: $(PROJECTS))
endif
ifneq ($(filter $(strip $(PROJECT)),$(PROJECTS)),$(strip $(PROJECT)))
$(error Unknown PROJECT. Choose $(PROJECTS))
endif
SELECTED_PROJECTS := $(filter $(strip $(PROJECT)),$(PROJECTS))
else
SELECTED_PROJECTS := $(PROJECTS)
endif

.PHONY: help build test fmt fmt-check check clean install

help:
	@printf '%s\n' \
	  'SazareMono — independent Foundry projects in one Git repository' \
	  '' \
	  'make install    Initialize all Git submodule dependencies' \
	  'make build      Build all projects' \
	  'make test       Test all projects' \
	  'make fmt        Format all projects' \
	  'make fmt-check  Check formatting in all projects' \
	  'make check      Check formatting, build, then test' \
	  'make clean      Remove all Foundry build artifacts' \
	  '' \
	  'Select one project: make test PROJECT=tokens' \
	  'Available projects: tokens, hooks, add-ons'

build test fmt fmt-check clean:
	@set -eu; \
	for project in $(SELECTED_PROJECTS); do \
	  printf '\n%s: %s\n' "$$project" '$@'; \
	  case '$@' in \
	    fmt-check) forge fmt --check --root "$$project" ;; \
	    *) forge '$@' --root "$$project" ;; \
	  esac; \
	done

check:
	@$(MAKE) fmt-check
	@$(MAKE) build
	@$(MAKE) test

install:
	git submodule update --init --recursive
