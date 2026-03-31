PLIST_NAME  = com.user.heatstroke.plist
PLIST_SRC   = $(shell pwd)/$(PLIST_NAME)
PLIST_DEST  = $(HOME)/Library/LaunchAgents/$(PLIST_NAME)
LOG_FILE    = $(HOME)/.local/state/heatstroke/watchdog.log

.PHONY: install uninstall start stop restart status log test

install: ## Symlink plist and load the launch agent
	ln -sf "$(PLIST_SRC)" "$(PLIST_DEST)"
	launchctl load "$(PLIST_DEST)"
	@echo "Heatstroke installed and running."

uninstall: stop ## Unload and remove the launch agent
	rm -f "$(PLIST_DEST)"
	@echo "Heatstroke uninstalled."

start: ## Load the launch agent
	launchctl load "$(PLIST_DEST)"

stop: ## Unload the launch agent
	launchctl unload "$(PLIST_DEST)" 2>/dev/null || true

restart: stop start ## Restart the launch agent

status: ## Show whether the agent is running
	@launchctl list | grep heatstroke || echo "Not running"

log: ## Tail the log
	@tail -f "$(LOG_FILE)"

test: ## Run the test suite
	@bash test-heatstroke.sh

help: ## List available commands
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
