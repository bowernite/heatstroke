PLIST_NAME  = com.user.heatstroke.plist
PLIST_DEST  = $(HOME)/Library/LaunchAgents/$(PLIST_NAME)
SCRIPT_PATH = $(shell pwd)/heatstroke.sh
LOG_FILE    = $(HOME)/.local/state/heatstroke/watchdog.log
APP_SRC     = $(shell pwd)/Heatstroke.app
APP_DEST    = $(HOME)/Applications/Heatstroke.app

.PHONY: install uninstall start stop restart status log test app

app: ## Build the stub Heatstroke.app (icon + bundle ID for notifications)
	@bash create-app-icon.sh

install: app ## Build app, install, and load the launch agent
	launchctl unload "$(PLIST_DEST)" 2>/dev/null || true
	@rm -rf "$(APP_DEST)"
	@cp -R "$(APP_SRC)" "$(APP_DEST)"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(APP_DEST)"
	@echo "Installed Heatstroke.app to ~/Applications"
	@sed 's|__SCRIPT_PATH__|$(SCRIPT_PATH)|g' com.user.heatstroke.plist.template > "$(PLIST_DEST)"
	launchctl load "$(PLIST_DEST)"
	@echo "Heatstroke installed and running."

uninstall: stop ## Unload and remove the launch agent and app
	rm -f "$(PLIST_DEST)"
	rm -rf "$(APP_DEST)"
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
