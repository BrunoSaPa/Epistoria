#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
label="com.epistoria.worker"
domain="gui/$(id -u)"
launch_agents="$HOME/Library/LaunchAgents"
plist="$launch_agents/$label.plist"
template="$project_root/infra/launchd/$label.plist.template"
environment_file="${EPISTORIA_WORKER_ENV_FILE:-$project_root/services/worker/.env}"
log_directory="$HOME/Library/Logs/EpistoriaWorker"

usage() {
  printf 'Usage: %s <install|uninstall|restart|status|doctor>\n' "$0" >&2
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'The Epistoria worker LaunchAgent is available only on macOS.\n' >&2
    exit 1
  fi
}

service_loaded() {
  launchctl print "$domain/$label" >/dev/null 2>&1
}

install_service() {
  require_macos
  "$project_root/scripts/run-worker.sh" --env-file "$environment_file" doctor
  mkdir -p "$launch_agents" "$log_directory"
  chmod 700 "$log_directory"
  install -m 600 "$template" "$plist"
  plutil -replace ProgramArguments.0 -string "$project_root/scripts/run-worker.sh" "$plist"
  plutil -replace ProgramArguments.2 -string "$environment_file" "$plist"
  plutil -replace StandardOutPath -string "$log_directory/worker.log" "$plist"
  plutil -replace StandardErrorPath -string "$log_directory/worker-error.log" "$plist"
  plutil -lint "$plist" >/dev/null
  if service_loaded; then
    launchctl bootout "$domain/$label"
  fi
  launchctl bootstrap "$domain" "$plist"
  launchctl kickstart -k "$domain/$label"
  printf 'Installed and started %s. No secrets were written to the plist.\n' "$label"
}

uninstall_service() {
  require_macos
  if service_loaded; then
    launchctl bootout "$domain/$label"
  fi
  if [[ -f "$plist" && ! -L "$plist" ]]; then
    rm -f -- "$plist"
  fi
  printf 'Uninstalled %s. Worker logs and Keychain material were preserved.\n' "$label"
}

status_service() {
  require_macos
  if service_loaded; then
    launchctl print "$domain/$label" | sed -n \
      -e '/state =/p' \
      -e '/pid =/p' \
      -e '/last exit code =/p' \
      -e '/runs =/p'
    printf 'Logs: %s\n' "$log_directory"
  else
    printf '%s is not loaded.\n' "$label"
    exit 3
  fi
}

case "${1:-}" in
  install) install_service ;;
  uninstall) uninstall_service ;;
  restart)
    require_macos
    if ! service_loaded; then
      printf '%s is not loaded; run install first.\n' "$label" >&2
      exit 3
    fi
    launchctl kickstart -k "$domain/$label"
    printf 'Restarted %s.\n' "$label"
    ;;
  status) status_service ;;
  doctor) "$project_root/scripts/run-worker.sh" --env-file "$environment_file" doctor ;;
  *) usage; exit 2 ;;
esac
