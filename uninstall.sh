#!/bin/bash
# uninstall.sh - remove zmbkposev3 from a server

OSE_SRC="/usr/local/bin"
OSE_BIN="zmbkposev3"
MAIN_BIN="${OSE_BIN}-main"
UNINSTALL_BIN="${OSE_BIN}-uninstall"
OSE_CONF="/etc/zmbkposev3"
OSE_CONF_FILE="zmbkpose.conf"
INITD_DIR="/etc/init.d"
LOG_DIR="/var/log/zmbkpose"
STATE_DIR="/var/lib/zmbkpose"
PID_FILE="/var/run/zmbkpose/zmbkposev3-main.pid"

ASSUME_YES=no
PURGE_CONFIG=no
PURGE_LOGS=no
PURGE_STATE=no
PURGE_SFTP_KEY=no

function show_help(){
	cat<<-EOF
Usage: uninstall.sh [options]

Options:
  --yes             Do not ask confirmation
  --purge-config    Remove $OSE_CONF
  --purge-logs      Remove $LOG_DIR
  --purge-state     Remove $STATE_DIR
  --purge-sftp-key  Remove SFTP_IDENTITY_FILE and SFTP_IDENTITY_FILE.pub
  --purge-all       Remove config, logs, state, and configured SFTP key
  -h, --help        Show this help

Backup files in WORKDIR are never removed by this uninstaller.
EOF
}

function item_msg(){
	printf '  - %s\n' "$*"
}

function ok_msg(){
	printf '[OK] %s\n' "$*"
}

function warn_msg(){
	printf '[WARN] %s\n' "$*" >&2
}

function error_msg(){
	printf '[ERROR] %s\n' "$*" >&2
}

function confirm(){
	local prompt="$1"
	local answer

	[ "$ASSUME_YES" = yes ] && return 0
	printf '%s [y/N]: ' "$prompt"
	read -r answer
	case "$answer" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

function load_config(){
	if [ -r "$OSE_CONF/$OSE_CONF_FILE" ];then
		source "$OSE_CONF/$OSE_CONF_FILE"
		[ -n "$SCHEDULER_PID_FILE" ] && PID_FILE="$SCHEDULER_PID_FILE"
		[ -n "$SCHEDULER_STATE_DIR" ] && STATE_DIR="$SCHEDULER_STATE_DIR"
	fi
}

function safe_dir_for_removal(){
	case "$1" in
		""|"/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/usr/local"|"/var"|"/var/lib"|"/var/log")
			return 1
		;;
	esac
	return 0
}

function remove_file(){
	local file="$1"

	if [ -e "$file" ] || [ -L "$file" ];then
		rm -f "$file" && ok_msg "Removed $file" || warn_msg "Could not remove $file"
	else
		item_msg "Not found: $file"
	fi
}

function remove_dir(){
	local dir="$1"
	local label="$2"

	if [ ! -e "$dir" ];then
		item_msg "Not found: $dir"
		return 0
	fi
	if ! safe_dir_for_removal "$dir";then
		error_msg "Refusing to remove unsafe $label directory: $dir"
		return 1
	fi
	rm -rf "$dir" && ok_msg "Removed $label directory $dir" || warn_msg "Could not remove $dir"
}

function stop_service(){
	local init_script="$INITD_DIR/$OSE_BIN"

	if [ -x "$init_script" ];then
		"$init_script" stop >/dev/null 2>&1 || true
		ok_msg "Stopped service if it was running"
	elif [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null;then
		kill "$(cat "$PID_FILE")" 2>/dev/null || true
		ok_msg "Stopped scheduler process from $PID_FILE"
	else
		item_msg "Service is not running"
	fi
}

function disable_service(){
	if command -v update-rc.d >/dev/null 2>&1;then
		update-rc.d -f "$OSE_BIN" remove >/dev/null 2>&1 || true
		ok_msg "Removed boot startup entry with update-rc.d"
	elif command -v chkconfig >/dev/null 2>&1;then
		chkconfig --del "$OSE_BIN" >/dev/null 2>&1 || true
		ok_msg "Removed boot startup entry with chkconfig"
	else
		item_msg "No update-rc.d/chkconfig command found"
	fi
}

function purge_sftp_key(){
	if [ -z "$SFTP_IDENTITY_FILE" ];then
		item_msg "No SFTP_IDENTITY_FILE configured"
		return 0
	fi

	remove_file "$SFTP_IDENTITY_FILE"
	remove_file "${SFTP_IDENTITY_FILE}.pub"
}

while [ -n "$1" ];do
	case "$1" in
		--yes)
			ASSUME_YES=yes
			shift
		;;
		--purge-config)
			PURGE_CONFIG=yes
			shift
		;;
		--purge-logs)
			PURGE_LOGS=yes
			shift
		;;
		--purge-state)
			PURGE_STATE=yes
			shift
		;;
		--purge-sftp-key)
			PURGE_SFTP_KEY=yes
			shift
		;;
		--purge-all)
			PURGE_CONFIG=yes
			PURGE_LOGS=yes
			PURGE_STATE=yes
			PURGE_SFTP_KEY=yes
			shift
		;;
		-h|--help)
			show_help
			exit 0
		;;
		*)
			error_msg "Unknown option: $1"
			show_help
			exit 1
		;;
	esac
done

if [ "$(id -u)" -ne 0 ];then
	error_msg "You need root privileges to uninstall $OSE_BIN"
	exit 2
fi

load_config

cat<<-EOF
zmbkposev3 uninstaller

Will remove:
  - $INITD_DIR/$OSE_BIN
  - $OSE_SRC/$OSE_BIN
  - $OSE_SRC/$MAIN_BIN
  - $OSE_SRC/$UNINSTALL_BIN
  - $PID_FILE
EOF
[ "$PURGE_CONFIG" = yes ] && item_msg "Purge config: $OSE_CONF"
[ "$PURGE_LOGS" = yes ] && item_msg "Purge logs: $LOG_DIR"
[ "$PURGE_STATE" = yes ] && item_msg "Purge state: $STATE_DIR"
[ "$PURGE_SFTP_KEY" = yes ] && item_msg "Purge SFTP key: ${SFTP_IDENTITY_FILE:-not configured}"
[ -n "$WORKDIR" ] && item_msg "Backup files kept: $WORKDIR"
printf '\nBackup files in WORKDIR are never removed by this script.\n\n'

confirm "Continue uninstall?" || {
	echo "Aborted."
	exit 1
}

stop_service
disable_service
remove_file "$INITD_DIR/$OSE_BIN"
remove_file "$OSE_SRC/$OSE_BIN"
remove_file "$OSE_SRC/$MAIN_BIN"
remove_file "$PID_FILE"

[ "$PURGE_SFTP_KEY" = yes ] && purge_sftp_key
[ "$PURGE_CONFIG" = yes ] && remove_dir "$OSE_CONF" "config"
[ "$PURGE_STATE" = yes ] && remove_dir "$STATE_DIR" "state"
[ "$PURGE_LOGS" = yes ] && remove_dir "$LOG_DIR" "log"

remove_file "$OSE_SRC/$UNINSTALL_BIN"
ok_msg "$OSE_BIN uninstall completed"
