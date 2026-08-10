BROKKR_SSH_TARGET ?= brokkr@control-node
BROKKR_REMOTE_DIR ?= /opt/brokkr
export OVERLAY COMMIT

.PHONY: patching maintenance-os maintenance-deps offsite-photos offsite-photos-dryrun offsite-photos-install deploy-control-node node-inventory inspect relocation-plan relocation-apply maintenance-plan maintenance-controller maintenance-executor m5-fde-preflight systemd-supervision-audit m5-network-render m5-network-preflight test shellcheck

patching: ## Install/refresh unattended-upgrades on all Pi hosts (ARGS="--dry-run" or a host)
	@./scripts/setup-host-patching.sh $(ARGS)

offsite-photos: ## Run the offsite Photos backup now (on the laptop)
	@./scripts/offsite-photos-backup.sh

offsite-photos-dryrun: ## Dry-run the offsite Photos backup (touches nothing)
	@./scripts/offsite-photos-backup.sh --dry-run

offsite-photos-install: ## Install/refresh the offsite-photos LaunchAgent (daily 04:15)
	@./launchd/install.sh

deploy-control-node: ## Deploy from an owner-only overlay (OVERLAY=/absolute/file COMMIT=full-sha)
	@test -n "$$OVERLAY" || { echo "OVERLAY=/absolute/owner-only-overlay.json is required" >&2; exit 64; }
	@test -n "$$COMMIT" || { echo "COMMIT=accepted-full-sha is required" >&2; exit 64; }
	@python3 profiles/deploy-control-node.py --overlay "$$OVERLAY" --commit "$$COMMIT"

node-inventory: ## Emit a read-only v1 node-capability JSON record (human status on stderr)
	@node scripts/node-inventory.mjs $(ARGS)

inspect: ## Controller-side, bounded inspection (ARGS="stable-node-id")
	@node scripts/brokkr.mjs inspect $(ARGS)

relocation-plan: ## Produce a deterministic, read-only relocation preflight plan (ARGS="...")
	@node scripts/relocation-planner.mjs $(ARGS)

relocation-apply: ## Execute a bounded relocation lifecycle (explicit plan/operation/journal only)
	@node scripts/relocation-lifecycle.mjs $(ARGS)

maintenance-plan: ## Produce a deterministic, read-only maintenance observation/plan (ARGS="...")
	@node scripts/maintenance-plan.mjs $(ARGS)

maintenance-controller: ## Inspect fail-closed maintenance-controller admission (ARGS="...")
	@node scripts/maintenance-controller.mjs $(ARGS)

maintenance-executor: ## Inspect the disarmed Debian host-adapter contract; no live host adapter is installed
	@echo "Host adapter is disarmed; owner ceremony and exact root-owned registration are required."

m5-fde-preflight: ## Run the read-only M5 FDE ceremony gate (ARGS="--copy-observed-at ...")
	@./scripts/m5-fde-preflight.sh $(ARGS)

systemd-supervision-audit: ## Audit systemd projection (real clock; replay --now requires BROKKR_SYSTEMD_AUDIT_ALLOW_REPLAY=1)
	@node scripts/systemd-supervision-audit.mjs $(ARGS)

m5-network-render: ## Render the M5 default-deny plan (CONFIG=/root-owned/profile)
	@test -n "$(CONFIG)" || { echo "CONFIG=/root-owned/profile is required" >&2; exit 64; }
	@./scripts/m5-network-profile.py render --config "$(CONFIG)"

m5-network-preflight: ## Run the non-mutating M5 network-profile gate (CONFIG=...)
	@test -n "$(CONFIG)" || { echo "CONFIG=/root-owned/profile is required" >&2; exit 64; }
	@./scripts/m5-network-profile.py preflight --config "$(CONFIG)"

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
