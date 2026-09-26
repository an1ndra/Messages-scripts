#!/usr/bin/env bash
# End-to-end UI test sweep: builds, installs, then exercises every feature,
# saving numbered screenshots into screenshots/.
source "$(dirname "$0")/env.sh"
S="$(dirname "$0")"

run() { info "RUNNING: $*"; "$@" || echo "[warn] $* failed"; }

run bash "$S/install.sh"
run bash "$S/grant-permissions.sh"
run bash "$S/open-app.sh"
run bash "$S/receive-sms.sh" 15551337777 "Automated inbound test SMS"
run bash "$S/send-message.sh" 1 "Automated outbound test message"
run bash "$S/new-message.sh" 15559990001 "Hello new conversation"
run bash "$S/settings.sh"
run bash "$S/theme.sh" dark
run bash "$S/theme.sh" light
run bash "$S/theme.sh" system
run bash "$S/test-notification-posts.sh"
run bash "$S/test-notification-icon.sh"
run bash "$S/test-backup-restore.sh"
run bash "$S/test-issue-183-split-threads.sh"
run bash "$S/test-import-mirrors-provider.sh"
run bash "$S/test-merge-import.sh"
run bash "$S/test-import-loading.sh"
run bash "$S/test-font.sh"
run bash "$S/test-advanced-move.sh"
run bash "$S/test-crash-reports.sh"
run bash "$S/test-diagnostics.sh"
run bash "$S/test-sim-label.sh"
run bash "$S/test-display-mode.sh"
run bash "$S/test-keywords.sh"
run bash "$S/test-android12-launch.sh"
run bash "$S/test-fake-dual-sim.sh"
run bash "$S/test-sim-inputbar.sh"
run bash "$S/test-persian-numbers.sh"
run bash "$S/test-24h-time.sh"
run bash "$S/test-emoji-toggle.sh"
run bash "$S/test-spam-blocked.sh"
run bash "$S/test-mms-import.sh"
run bash "$S/test-mms-download.sh"
run bash "$S/test-mms-send.sh"
run bash "$S/test-mms-pdu-bytes.sh"
run bash "$S/test-backup-sim-coil.sh"
run bash "$S/test-bubble-corners.sh"
run bash "$S/test-codeql-cleanup.sh"
run bash "$S/test-translations.sh"

info "ALL DONE — screenshots in $SHOTS_DIR"
