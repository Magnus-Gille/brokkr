BROKKR_SSH_TARGET ?= brokkr@control-node
BROKKR_REMOTE_DIR ?= /opt/brokkr

.PHONY: patching maintenance-os maintenance-deps offsite-photos offsite-photos-dryrun offsite-photos-install node-inventory relocation-plan test shellcheck

patching: ## Install/refresh unattended-upgrades on all Pi hosts (ARGS="--dry-run" or a host)
	@./scripts/setup-host-patching.sh $(ARGS)

offsite-photos: ## Run the offsite Photos backup now (on the laptop)
	@./scripts/offsite-photos-backup.sh

offsite-photos-dryrun: ## Dry-run the offsite Photos backup (touches nothing)
	@./scripts/offsite-photos-backup.sh --dry-run

offsite-photos-install: ## Install/refresh the offsite-photos LaunchAgent (daily 04:15)
	@./launchd/install.sh

node-inventory: ## Emit a read-only v1 node-capability JSON record (human status on stderr)
	@node scripts/node-inventory.mjs $(ARGS)

relocation-plan: ## Produce a deterministic, read-only relocation preflight plan (ARGS="...")
	@node scripts/relocation-planner.mjs $(ARGS)

maintenance-os: ## Run the OS maintenance report on the service host (ARGS="--dry-run --verbose")
	@ssh $(BROKKR_SSH_TARGET) 'cd $(BROKKR_REMOTE_DIR) && bash scripts/maintenance-report.sh os $(ARGS)'

maintenance-deps: ## Run the npm dependency report on the service host (ARGS="--dry-run --verbose")
	@ssh $(BROKKR_SSH_TARGET) 'cd $(BROKKR_REMOTE_DIR) && bash scripts/maintenance-report.sh deps $(ARGS)'

test: ## Run every hermetic operational script test
	@set -e; for test in scripts/test/*.test.sh; do echo "== $$test =="; bash "$$test"; done

shellcheck: ## Lint every shell script at warning severity
	@find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -S warning

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
