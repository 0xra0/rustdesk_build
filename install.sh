#!/usr/bin/bash
# Install the RustDesk Linux bundle staged in pkg/ onto the local system.
# Supports runit (Void/Artix) and systemd.
#
# Usage: bash install.sh [options]
#   -n, --dry-run         Print actions without modifying the system
#       --no-restart      Do not stop/start the background service around install
#       --enable-service  Enable the runit or systemd service if not enabled
#   -h, --help            Show this help message
set -euo pipefail

_scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_pkgdir="${_scriptdir}/pkg"
_pkgname='rustdesk'

_dry_run=0
_restart=1
_enable_service=0

msg()     { printf '\033[1;32m==> \033[0m\033[1m%s\033[0m\n' "$*"; }
msg2()    { printf '\033[1;34m  -> \033[0m%s\n' "$*"; }
warning() { printf '\033[1;33m==> WARNING: \033[0m%s\n' "$*" >&2; }
error()   { printf '\033[1;31m==> ERROR: \033[0m%s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run)        _dry_run=1 ;;
    --no-restart)        _restart=0 ;;
    --enable-service)    _enable_service=1 ;;
    -h|--help)           usage ;;
    *) error "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

[ -x "${_pkgdir}/usr/lib/${_pkgname}/${_pkgname}" ] \
  || error "Built package not found at ${_pkgdir}/usr/lib/${_pkgname}/${_pkgname}. Run 'bash build.sh' first."

_version="$(sed -n 's/^Version=//p' "${_pkgdir}/usr/share/applications/${_pkgname}.desktop" 2>/dev/null | head -n1)"
_version="${_version:-unknown}"

if [ "${_dry_run}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || error "Root privileges required (run as root or install sudo)."
  msg "Elevating privileges with sudo"
  exec sudo -- "$0" "$@"
fi

_run() {
  if [ "${_dry_run}" -ne 0 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

_was_runit_running=0
_was_systemd_running=0

if [ "${_restart}" -ne 0 ]; then
  if command -v sv >/dev/null 2>&1 && [ -e "/var/service/${_pkgname}" ]; then
    if sv status "${_pkgname}" 2>/dev/null | grep -q '^run:'; then
      _was_runit_running=1
      msg "Stopping runit service (${_pkgname})"
      _run sv down "${_pkgname}" || true
      if [ "${_dry_run}" -eq 0 ]; then
        sleep 1
      fi
    fi
  elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if systemctl is-active --quiet "${_pkgname}"; then
      _was_systemd_running=1
      msg "Stopping systemd service (${_pkgname})"
      _run systemctl stop "${_pkgname}"
    fi
  fi
fi

msg "Installing ${_pkgname} ${_version} from ${_pkgdir}"

# Replace /usr/lib/rustdesk cleanly so stale shared libraries from older builds do not remain.
msg2 "Installing /usr/lib/${_pkgname} and /usr/bin/${_pkgname}"
_run rm -rf -- "/usr/lib/${_pkgname}"
_run install -d /usr/lib /usr/bin
_run cp -a "${_pkgdir}/usr/lib/${_pkgname}" "/usr/lib/${_pkgname}"
_run ln -sfn "/usr/lib/${_pkgname}/${_pkgname}" "/usr/bin/${_pkgname}"

# Desktop entry, icons, and license
if [ -f "${_pkgdir}/usr/share/applications/${_pkgname}.desktop" ]; then
  msg2 "Installing desktop entry"
  _run install -Dm0644 "${_pkgdir}/usr/share/applications/${_pkgname}.desktop" \
    "/usr/share/applications/${_pkgname}.desktop"
fi

for _size in 32x32 128x128 256x256; do
  _icon="${_pkgdir}/usr/share/icons/hicolor/${_size}/apps/${_pkgname}.png"
  if [ -f "${_icon}" ]; then
    _run install -Dm0644 "${_icon}" \
      "/usr/share/icons/hicolor/${_size}/apps/${_pkgname}.png"
  fi
done

if [ -f "${_pkgdir}/usr/share/licenses/${_pkgname}/LICENCE" ]; then
  _run install -Dm0644 "${_pkgdir}/usr/share/licenses/${_pkgname}/LICENCE" \
    "/usr/share/licenses/${_pkgname}/LICENCE"
fi

# Service definitions (install individual files so active runit supervise/ state is preserved)
if [ -f "${_pkgdir}/usr/lib/systemd/system/${_pkgname}.service" ]; then
  msg2 "Installing systemd unit"
  _run install -Dm0644 "${_pkgdir}/usr/lib/systemd/system/${_pkgname}.service" \
    "/usr/lib/systemd/system/${_pkgname}.service"
fi

if [ -d "${_pkgdir}/etc/sv/${_pkgname}" ]; then
  msg2 "Installing runit service scripts"
  for _f in run finish control/t log/run; do
    if [ -f "${_pkgdir}/etc/sv/${_pkgname}/${_f}" ]; then
      _run install -Dm0755 "${_pkgdir}/etc/sv/${_pkgname}/${_f}" \
        "/etc/sv/${_pkgname}/${_f}"
    fi
  done
fi

if [ "${_dry_run}" -eq 0 ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
fi

# Restart or enable background service
if [ -d /run/runit ] && command -v sv >/dev/null 2>&1; then
  if [ "${_enable_service}" -ne 0 ] && [ ! -e "/var/service/${_pkgname}" ]; then
    msg "Enabling runit service"
    _run ln -s "/etc/sv/${_pkgname}" "/var/service/${_pkgname}"
  elif [ "${_was_runit_running}" -ne 0 ]; then
    msg "Starting runit service (${_pkgname})"
    _run sv up "${_pkgname}"
  elif [ ! -e "/var/service/${_pkgname}" ]; then
    msg2 "To enable the runit service: sudo ln -s /etc/sv/${_pkgname} /var/service/"
  fi
elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  _run systemctl daemon-reload
  if [ "${_enable_service}" -ne 0 ]; then
    msg "Enabling and starting systemd service (${_pkgname})"
    _run systemctl enable --now "${_pkgname}"
  elif [ "${_was_systemd_running}" -ne 0 ]; then
    msg "Starting systemd service (${_pkgname})"
    _run systemctl start "${_pkgname}"
  fi
fi

msg "Installed ${_pkgname} ${_version}"
