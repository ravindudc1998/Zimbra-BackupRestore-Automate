#!/bin/bash -e
# install.sh
# This script installs zmbkposev3 on your server. It also makes sure
# the script's dependencies are present.
#
# You don't need install zmbkposev3 on a zimbra server. It's not a requirement.
#
# NOTE: This script try to detect if you are on a zimbra host. It will check
# if zimbra user exist and if it is execute capable of  zmlocalconfig command.
# If a zimbra installation is detected, this script will try to configure zmbkposev3
#
#--------------------------------------------------------------------------------
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Zmbkpose Defaults - Where the script will be placed and look for its settings
OSE_SRC="/usr/local/bin"
OSE_BIN="zmbkposev3"
OSE_CONF="/etc/zmbkposev3"
OSE_CONF_FILE="zmbkpose.conf"
LOG_DIR="/var/log/zmbkpose"
INSTALL_LOG_FILE="$LOG_DIR/zmbkpose-installation.log"
MAIN_BIN="${OSE_BIN}-main"
UNINSTALL_BIN="${OSE_BIN}-uninstall"
MAIN_LOG_FILE="$LOG_DIR/zmbkpose-main.log"
BACKUP_LOG_FILE="$LOG_DIR/zmbkpose-backup.log"
BACKUP_LOG_HEADER="start_time,email,backup_location,backup_size,end_time,zmbkpose_command"
RESTORE_LOG_FILE="$LOG_DIR/zmbkpose-restore.log"
RESTORE_LOG_HEADER="start_time,email,backup_location,backup_size,end_time,zmbkpose_command,status"
INITD_DIR="/etc/init.d"
STATE_DIR="/var/lib/zmbkpose"
PID_FILE="/var/run/zmbkpose/zmbkposev3-main.pid"

FULL_BACKUP_TIME="00:00"
INCREMENTAL_BACKUP_TIMES="06:00 09:00 18:00 21:00"
BACKUP_KEEP_FULL="3"
BACKUP_RETRY_COUNT="3"
BACKUP_RETRY_WAIT_SECONDS="300"
REMOTE_COPY_ENABLED="no"
REMOTE_COPY_METHOD="rsync"
RSYNC_ENABLED="no"
RSYNC_TARGET=""
RSYNC_OPTIONS="-a --partial --delay-updates"
RSYNC_DELETE="no"
RSYNC_BWLIMIT=""
RSYNC_SSH_PORT=""
SFTP_TARGET=""
SFTP_PORT="22"
SFTP_IDENTITY_FILE=""
SFTP_OPTIONS="-oBatchMode=yes -oStrictHostKeyChecking=accept-new"
SFTP_GENERATE_KEY="yes"

# Zimbra Defaults - Change these if you compiled zimbra yourself with different 
# settings
ZIMBRA_USER="zimbra"
ZIMBRA_DIR="/opt/zimbra"
EXTRA_COMMAND_PATHS="$ZIMBRA_DIR/bin:$ZIMBRA_DIR/common/bin:$ZIMBRA_DIR/openldap/bin:$ZIMBRA_DIR/postfix/sbin"
ZMBKPOSE_BKDIR=""		# Leave empty to autodetect
ZIMBRA_HOSTNAME=""		# Leave empty to autodetect
ZIMBRA_ADDRESS=""		# Leave empty to autodetect
ZIMBRA_LDAPPASS=""		# Leave empty to autodetect


# Exit codes
ERR_OK="0"			# No error (normal exit)
ERR_NOBKPDIR="1"		# No backup directory could be found
ERR_NOROOT="2"			# Script was run without root privileges
ERR_DEPNOTFOUND="3"		# Missing dependency
ERR_MISSINGFILES="4"		# Missing files
ERR_NO_EXEC_USER="5"		# No user for zmbkposev3 execution

function error(){ echo "ERROR: $@" ; }

function item_check_msg(){ printf '%-40s...' "$@" ; }

function item_msg(){ printf '  -%-40s\n' "$@" ; }

function sub_item_check_msg(){ printf '  %-37s...' "$@" ; }

function read_y_n_question(){
	echo -n "$1 [y/n]: "
	while read -s -n 1 r;do
		[ "$r" = y ]  && echo "[YES]" && return 0
		[ "$r" = n ]  && echo "[NO]" && return 1
	done
}

function read_default_question(){
	local prompt="$1"
	local default_value="$2"
	local answer

	printf '%s [%s]: ' "$prompt" "$default_value" >&2
	read -r answer
	if [ -z "$answer" ];then
		echo "$default_value"
	else
		echo "$answer"
	fi
}

function is_hhmm_time(){
	echo "$1" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'
}

function normalize_time_list(){
	local value="$1"
	local time_value output
	output=

	for time_value in ${value//,/ };do
		[ -z "$time_value" ] && continue
		if ! is_hhmm_time "$time_value";then
			return 1
		fi
		output="${output}${output:+ }$time_value"
	done
	[ -n "$output" ] || return 1
	echo "$output"
}

function read_time_question(){
	local prompt="$1"
	local default_value="$2"
	local answer

	while true;do
		answer=$(read_default_question "$prompt" "$default_value")
		if is_hhmm_time "$answer";then
			echo "$answer"
			return 0
		fi
		echo "ERROR: Please use HH:MM 24-hour format, example 00:00 or 18:30" >&2
	done
}

function read_time_list_question(){
	local prompt="$1"
	local default_value="$2"
	local answer normalized

	while true;do
		answer=$(read_default_question "$prompt" "$default_value")
		if normalized=$(normalize_time_list "$answer");then
			echo "$normalized"
			return 0
		fi
		echo "ERROR: Please use HH:MM times separated by spaces or commas" >&2
	done
}

function read_number_question(){
	local prompt="$1"
	local default_value="$2"
	local answer

	while true;do
		answer=$(read_default_question "$prompt" "$default_value")
		if echo "$answer" | grep -Eq '^[0-9]+$';then
			echo "$answer"
			return 0
		fi
		echo "ERROR: Please enter 0 or a positive number" >&2
	done
}

function read_optional_number_question(){
	local prompt="$1"
	local default_value="$2"
	local answer

	while true;do
		answer=$(read_default_question "$prompt" "$default_value")
		if [ -z "$answer" ] || echo "$answer" | grep -Eq '^[0-9]+$';then
			echo "$answer"
			return 0
		fi
		echo "ERROR: Please enter a number or leave blank" >&2
	done
}

function read_choice_question(){
	local prompt="$1"
	local default_value="$2"
	local choices="$3"
	local answer choice

	while true;do
		answer=$(read_default_question "$prompt" "$default_value")
		for choice in $choices;do
			if [ "$answer" = "$choice" ];then
				echo "$answer"
				return 0
			fi
		done
		echo "ERROR: Please enter one of: $choices" >&2
	done
}

function shell_quote(){
	printf '%s\n' "$1" | sed "s/'/'\"'\"'/g; 1s/^/'/; \$s/\$/'/"
}

function get_user_home(){
	getent passwd "$1" | awk -F: '{print $6}'
}

function default_sftp_identity_file(){
	local user_home

	user_home=$(get_user_home "$ZMBKPOSE_USER")
	[ -n "$user_home" ] && printf '%s/.ssh/zmbkposev3_sftp\n' "$user_home"
}

function generate_sftp_identity_key(){
	local key_file key_dir pub_file key_file_q key_dir_q pub_file_q key_comment_q

	[ "$REMOTE_COPY_ENABLED" = yes ] || return 0
	[ "$REMOTE_COPY_METHOD" = sftp ] || return 0
	[ "$SFTP_GENERATE_KEY" = yes ] || return 0

	if [ -z "$SFTP_IDENTITY_FILE" ];then
		error "SFTP identity file is required to generate an SSH key."
		exit $ERR_DEPNOTFOUND
	fi

	key_file="$SFTP_IDENTITY_FILE"
	key_dir="${key_file%/*}"
	[ "$key_dir" = "$key_file" ] && key_dir=.
	pub_file="${key_file}.pub"
	key_file_q=$(shell_quote "$key_file")
	key_dir_q=$(shell_quote "$key_dir")
	pub_file_q=$(shell_quote "$pub_file")
	key_comment_q=$(shell_quote "zmbkposev3-sftp")

	item_check_msg "Generating SFTP SSH key"
	if su - "$ZMBKPOSE_USER" -c "test -f $key_file_q" >/dev/null 2>&1 ;then
		printf "[SKIP]\n"
		item_msg "SFTP private key already exists: $key_file"
	else
		su - "$ZMBKPOSE_USER" -c "mkdir -p $key_dir_q && chmod 700 $key_dir_q && ssh-keygen -t ed25519 -N '' -f $key_file_q -C $key_comment_q" >/dev/null
		su - "$ZMBKPOSE_USER" -c "chmod 600 $key_file_q && chmod 644 $pub_file_q" >/dev/null 2>&1 || true
		printf "[OK]\n"
		item_msg "SFTP private key: $key_file"
	fi

	if ! su - "$ZMBKPOSE_USER" -c "test -r $pub_file_q" >/dev/null 2>&1 ;then
		su - "$ZMBKPOSE_USER" -c "ssh-keygen -y -f $key_file_q > $pub_file_q && chmod 644 $pub_file_q" >/dev/null
	fi
}

function show_sftp_public_key_hint(){
	local pub_file pub_file_q

	[ "$REMOTE_COPY_ENABLED" = yes ] || return 0
	[ "$REMOTE_COPY_METHOD" = sftp ] || return 0
	[ -n "$SFTP_IDENTITY_FILE" ] || return 0

	pub_file="${SFTP_IDENTITY_FILE}.pub"
	pub_file_q=$(shell_quote "$pub_file")
	if su - "$ZMBKPOSE_USER" -c "test -r $pub_file_q" >/dev/null 2>&1 ;then
		cat<<-EOF

################################################################################
 Add this public key to the TrueNAS/FreeNAS SFTP user Authorized Keys:
		EOF
		su - "$ZMBKPOSE_USER" -c "cat $pub_file_q"
		cat<<-EOF

 Public key file: $pub_file
 Do not copy the private key. The private key stays on this mail server.
		EOF
	fi
}

function escape_sed_replacement(){
	printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

function set_config_value(){
	local config_file="$1"
	local key="$2"
	local value="$3"
	local escaped_value

	escaped_value=$(escape_sed_replacement "$value")
	if grep -q "^$key=" "$config_file";then
		sed -i "s|^$key=.*|$key=\"$escaped_value\"|" "$config_file"
	else
		printf '%s="%s"\n' "$key" "$value" >> "$config_file"
	fi
}

function collect_service_settings(){
	cat<<-EOF

################################################################################
 Scheduled service settings
	EOF
	FULL_BACKUP_TIME=$(read_time_question "Full backup time (24-hour HH:MM)" "$FULL_BACKUP_TIME")
	INCREMENTAL_BACKUP_TIMES=$(read_time_list_question "Incremental backup time(s), space/comma separated" "$INCREMENTAL_BACKUP_TIMES")
	BACKUP_KEEP_FULL=$(read_number_question "How many full backup cycles should be kept per account after a new full? 0 deletes all old cycles first" "$BACKUP_KEEP_FULL")
	BACKUP_RETRY_COUNT=$(read_number_question "How many times should a failed scheduled backup retry?" "$BACKUP_RETRY_COUNT")
	BACKUP_RETRY_WAIT_SECONDS=$(read_number_question "Seconds to wait between failed scheduled backup retries" "$BACKUP_RETRY_WAIT_SECONDS")

	if read_y_n_question "Do you want to copy backups to a separate remote location?" ;then
		REMOTE_COPY_ENABLED=yes
		REMOTE_COPY_METHOD=$(read_choice_question "Remote copy method (rsync/sftp)" "$REMOTE_COPY_METHOD" "rsync sftp")
		if [ "$REMOTE_COPY_METHOD" = rsync ];then
			RSYNC_ENABLED=yes
			while [ -z "$RSYNC_TARGET" ];do
				RSYNC_TARGET=$(read_default_question "Rsync target, example backup@server:/backup/mailbackup-files/" "$RSYNC_TARGET")
				[ -n "$RSYNC_TARGET" ] || echo "ERROR: Rsync target is required when rsync is enabled" >&2
			done
			RSYNC_OPTIONS=$(read_default_question "Rsync options" "$RSYNC_OPTIONS")
			RSYNC_SSH_PORT=$(read_optional_number_question "Rsync SSH port, blank for default" "$RSYNC_SSH_PORT")
			RSYNC_BWLIMIT=$(read_optional_number_question "Rsync bandwidth limit, blank for unlimited" "$RSYNC_BWLIMIT")
			if read_y_n_question "Should rsync delete remote files missing from local backup storage?" ;then
				RSYNC_DELETE=yes
			else
				RSYNC_DELETE=no
			fi
		else
			RSYNC_ENABLED=no
			echo "INFO: SFTP copy uses SSH key or passwordless login; passwords are not saved in zmbkpose.conf."
			while [ -z "$SFTP_TARGET" ];do
				SFTP_TARGET=$(read_default_question "SFTP target, example backup@server:/backup/mailbackup-files/" "$SFTP_TARGET")
				[ -n "$SFTP_TARGET" ] || echo "ERROR: SFTP target is required when sftp is enabled" >&2
			done
			SFTP_PORT=$(read_optional_number_question "SFTP SSH port, 22 for default" "$SFTP_PORT")
			if [ -z "$SFTP_IDENTITY_FILE" ];then
				SFTP_IDENTITY_FILE=$(default_sftp_identity_file)
			fi
			SFTP_IDENTITY_FILE=$(read_default_question "SFTP identity file, blank for default ssh key" "$SFTP_IDENTITY_FILE")
			SFTP_OPTIONS=$(read_default_question "SFTP options" "$SFTP_OPTIONS")
			if [ -n "$SFTP_IDENTITY_FILE" ] && read_y_n_question "Generate SFTP SSH key now if missing?" ;then
				SFTP_GENERATE_KEY=yes
			else
				SFTP_GENERATE_KEY=no
			fi
		fi
	else
		REMOTE_COPY_ENABLED=no
		RSYNC_ENABLED=no
	fi
}

function init_install_log(){
	local log_group

	install -o root -g root -m 755 -d "$LOG_DIR"
	[ -e "$INSTALL_LOG_FILE" ] || touch "$INSTALL_LOG_FILE"
	log_group=adm
	getent group "$log_group" >/dev/null 2>&1 || log_group=root
	chown "root:$log_group" "$INSTALL_LOG_FILE" 2>/dev/null || true
	chmod 640 "$INSTALL_LOG_FILE" 2>/dev/null || true

	if command -v tee >/dev/null 2>&1;then
		exec > >(tee -a "$INSTALL_LOG_FILE") 2>&1
	else
		exec >> "$INSTALL_LOG_FILE" 2>&1
	fi
	INSTALL_LOG_STARTED=yes
	echo "################################################################################"
	echo "$(date '+%F %T') START: $OSE_BIN installer"
	echo "Installation log: $INSTALL_LOG_FILE"
}

function finish_install_log(){
	local status="$?"
	local result=OK

	[ "$INSTALL_LOG_STARTED" = yes ] || return "$status"
	[ "$status" -eq 0 ] || result=ERROR
	echo "$(date '+%F %T') $result: $OSE_BIN installer finished with status $status"
	return "$status"
}


function we_are_on_a_zimbra_host(){
	if 	! test -d $ZIMBRA_DIR  || \
		! grep -q "^$ZIMBRA_USER:" /etc/passwd || \
		! su - $ZIMBRA_USER -c zmlocalconfig >/dev/null 
	then
		echo false 
	else
		echo true
	fi
}


#Parse arguments
while [ -n "$1" ];do
	case "$1" in
		--zmbkdir) 
			[ -z "$2" ] && error "$1 require a argument value." && exit 1
			ZMBKPOSE_BKDIR="$2"
			shift 2
		;;
		--zmbkuser) 
			[ -z "$2" ] && error "$1 require a argument value." && exit 1
			ZMBKPOSE_USER="$2"
			shift 2
		;;
		--help|-h)
			cat<<-EOF
Zmbkpose v3 installer script :
 install.sh [--zmbkdir dir] [--zmbkuser user]
   --zmbkdir  dir   :Configure "dir" as directory for mailbox backups
   --zmbkuser user  :Configure user for execution of zmbkposev3. Default is "zimbra" if 
                       we are in a host with zimbra installed.
	EOF
			exit $ERR_OK
		;;
		*)
			error "\"$1\" : unknown argument"
			exit 1
		;;
	esac
done

# Check if we have root before doing anything
if [ $(id -u) -ne 0 ]; then
	error "You need root privileges to install zmbkposev3"
	exit $ERR_NOROOT
fi

init_install_log
trap finish_install_log EXIT

#We are on a zimbra host?
IS_A_ZIMBRA_HOST=$(we_are_on_a_zimbra_host)

# Try to guess missing settings as best as we can
item_check_msg 'Checking zimbra installation'
if $IS_A_ZIMBRA_HOST ;then
	echo '[OK]'
	ZMBKPOSE_USER=$ZIMBRA_USER
	test -z $ZIMBRA_HOSTNAME && \
		ZIMBRA_HOSTNAME=`su - $ZMBKPOSE_USER -c zmhostname`
	test -z $ZIMBRA_ADDRESS  && \
		ZIMBRA_ADDRESS=`grep "\b$ZIMBRA_HOSTNAME\b" /etc/hosts|awk '{print $1}'`
	test -z $ZIMBRA_LDAPDN   && \
		ZIMBRA_LDAPDN=`su - $ZMBKPOSE_USER -c "zmlocalconfig zimbra_ldap_userdn"|awk '{print $3}'`
	test -z $ZIMBRA_LDAPPASS && \
		ZIMBRA_LDAPPASS=`su - $ZMBKPOSE_USER -c "zmlocalconfig -s zimbra_ldap_password"|awk '{print $3}'`
	test -z "$ZIMBRA_ADMUSERS" && \
		ZIMBRA_ADMUSERS=`su - $ZMBKPOSE_USER -c 'zmprov getAllAdminAccounts'`
	if [ -z $ZMBKPOSE_BKDIR ]; then
	  test -d $ZIMBRA_DIR/backup && ZMBKPOSE_BKDIR=$ZIMBRA_DIR/backup
	fi
# No a zimbra host
else 
	echo '[NO]'
	if [ -z $ZMBKPOSE_BKDIR ]; then
		test -d /backup && ZMBKPOSE_BKDIR=/backup
		test -d /opt/backup && ZMBKPOSE_BKDIR=/opt/backup
	fi
fi

# Check user for execute zmbkposev3
if [ -z "$ZMBKPOSE_USER" ];then
	error "No user defined for zmbkposev3 execution. Please use --zmbkuser _user_"
	exit $ERR_NO_EXEC_USER
fi
if ! grep -q "^$ZMBKPOSE_USER:" /etc/passwd ;then
	error "User \"$ZMBKPOSE_USER\" doesn't exists"
	exit $ERR_NO_EXEC_USER
fi
item_msg "$OSE_BIN will use \"$ZMBKPOSE_USER\" user for execution."

#Zmbkpose backup dir check
if [ -z $ZMBKPOSE_BKDIR ]; then
	error "No backup directory could be found!. Please use --zmbkdir _dir_"
	exit $ERR_NOBKPDIR
fi
if [ ! -d $ZMBKPOSE_BKDIR ]; then
	error "Backup directory $ZMBKPOSE_BKDIR does not exists."
	exit $ERR_NOBKPDIR
fi

collect_service_settings

# Check for missing installer files
# TODO: MD5 check of the files
item_check_msg 'Checking installer integrity'
STATUS=0
MYDIR=`dirname $0`
test -f "$MYDIR/src/$OSE_BIN" || STATUS=$ERR_MISSINGFILES
test -f "$MYDIR/src/$MAIN_BIN" || STATUS=$ERR_MISSINGFILES
test -f "$MYDIR/uninstall.sh" || STATUS=$ERR_MISSINGFILES
test -f $MYDIR/etc/$OSE_CONF_FILE || STATUS=$ERR_MISSINGFILES
test -f "$MYDIR/etc/init.d/$OSE_BIN" || STATUS=$ERR_MISSINGFILES
if ! [ $STATUS = 0 ]; then
	echo '[NO]'
	error "Some files are missing. Please re-download the Zmbkpose installer."
	exit $STATUS
else
	echo '[OK]'
fi

# Check for missing dependencies
STATUS=0
item_check_msg 'Checking system for dependencies...'; echo

## Dependencies:No zimbra dependent
item_msg "Dependencies will be executed by \"$ZMBKPOSE_USER\" user"
DEPS="awk curl date diff du egrep find grep gzip ldapadd ldapsearch ln mktemp printf rm sed sort stat tar uniq readlink"
[ "$REMOTE_COPY_ENABLED" = yes -a "$REMOTE_COPY_METHOD" = rsync ] && DEPS="$DEPS rsync"
[ "$REMOTE_COPY_ENABLED" = yes -a "$REMOTE_COPY_METHOD" = sftp ] && DEPS="$DEPS sftp"
[ "$REMOTE_COPY_ENABLED" = yes -a "$REMOTE_COPY_METHOD" = sftp -a "$SFTP_GENERATE_KEY" = yes ] && DEPS="$DEPS ssh-keygen"
for dep_cmd in $DEPS;do
	sub_item_check_msg "$dep_cmd"
	if su - $ZMBKPOSE_USER -c "which $dep_cmd" >/dev/null 2>&1 ;then 
		printf "[OK]\n" 
	else 
		printf "[NOT FOUND]\n" 
		STATUS=$ERR_DEPNOTFOUND
	fi
done

## Dependencies: zimbra dependent
if $IS_A_ZIMBRA_HOST ;then
	DEPS=""
	for dep_cmd in $DEPS;do
		sub_item_check_msg "$dep_cmd"
		if su - $ZMBKPOSE_USER -c "PATH=\"$EXTRA_COMMAND_PATHS:\$PATH\" command -v $dep_cmd" >/dev/null 2>&1 ;then 
			printf "[OK]\n" 
		else 
			printf "[NOT FOUND]\n" 
			STATUS=$ERR_DEPNOTFOUND
		fi
	done
fi

## Done checking deps
if ! [ $STATUS = 0 ]; then
	echo ""
	echo "You're missing some dependencies OR they are not on $ZMBKPOSE_USER's PATH."
	echo "Please correct the problem and run the installer again."
	exit $STATUS
fi


# Installing
item_check_msg "Installing"
## Create directories if needed
install -o root -g root -m 755 -d $OSE_CONF
install -o root -g root -m 755 -d $OSE_SRC
install -o root -g root -m 755 -d $INITD_DIR
LOG_GROUP=adm
getent group "$LOG_GROUP" >/dev/null 2>&1 || LOG_GROUP=$(id -gn "$ZMBKPOSE_USER")
install -o "$ZMBKPOSE_USER" -g "$LOG_GROUP" -m 750 -d "$LOG_DIR"
install -o "$ZMBKPOSE_USER" -g "$LOG_GROUP" -m 750 -d "$STATE_DIR"
install -o "$ZMBKPOSE_USER" -g "$LOG_GROUP" -m 755 -d "${PID_FILE%/*}"
chown "root:$LOG_GROUP" "$INSTALL_LOG_FILE" 2>/dev/null || true
chmod 640 "$INSTALL_LOG_FILE" 2>/dev/null || true
[ -e "$MAIN_LOG_FILE" ] || touch "$MAIN_LOG_FILE"
chown "$ZMBKPOSE_USER:$LOG_GROUP" "$MAIN_LOG_FILE"
chmod 640 "$MAIN_LOG_FILE"
[ -e "$BACKUP_LOG_FILE" ] || printf '%s\n' "$BACKUP_LOG_HEADER" > "$BACKUP_LOG_FILE"
[ -s "$BACKUP_LOG_FILE" ] || printf '%s\n' "$BACKUP_LOG_HEADER" > "$BACKUP_LOG_FILE"
chown "$ZMBKPOSE_USER:$LOG_GROUP" "$BACKUP_LOG_FILE"
chmod 640 "$BACKUP_LOG_FILE"
[ -e "$RESTORE_LOG_FILE" ] || printf '%s\n' "$RESTORE_LOG_HEADER" > "$RESTORE_LOG_FILE"
[ -s "$RESTORE_LOG_FILE" ] || printf '%s\n' "$RESTORE_LOG_HEADER" > "$RESTORE_LOG_FILE"
chown "$ZMBKPOSE_USER:$LOG_GROUP" "$RESTORE_LOG_FILE"
chmod 640 "$RESTORE_LOG_FILE"
## Copy files
install -o $ZMBKPOSE_USER -m 700 "$MYDIR/src/$OSE_BIN" "$OSE_SRC/$OSE_BIN"
install -o $ZMBKPOSE_USER -m 700 "$MYDIR/src/$MAIN_BIN" "$OSE_SRC/$MAIN_BIN"
install -o root -g root -m 755 "$MYDIR/uninstall.sh" "$OSE_SRC/$UNINSTALL_BIN"
install --backup=numbered -o $ZMBKPOSE_USER -m 600 "$MYDIR/etc/$OSE_CONF_FILE" "$OSE_CONF/$OSE_CONF_FILE"
install -o root -g root -m 755 "$MYDIR/etc/init.d/$OSE_BIN" "$INITD_DIR/$OSE_BIN"
## Update OSE_CONF into the installed script
sed -i "s|^OSE_CONF=.*|OSE_CONF=\"$OSE_CONF\"|" "$OSE_SRC/$OSE_BIN"
sed -i "s|^OSE_CONF=.*|OSE_CONF=\"$OSE_CONF\"|" "$OSE_SRC/$MAIN_BIN"
sed -i "s|^OSE_BIN=.*|OSE_BIN=\"$OSE_SRC/$OSE_BIN\"|" "$OSE_SRC/$MAIN_BIN"
sed -i "s|^LOG_DIR=.*|LOG_DIR=\"$LOG_DIR\"|" "$OSE_SRC/$MAIN_BIN"
sed -i "s|^MAIN_LOG_FILE=.*|MAIN_LOG_FILE=\"$MAIN_LOG_FILE\"|" "$OSE_SRC/$MAIN_BIN"
sed -i "s|^STATE_DIR=.*|STATE_DIR=\"$STATE_DIR\"|" "$OSE_SRC/$MAIN_BIN"
sed -i "s|^OSE_SRC=.*|OSE_SRC=\"$OSE_SRC\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^OSE_BIN=.*|OSE_BIN=\"$OSE_BIN\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^OSE_CONF=.*|OSE_CONF=\"$OSE_CONF\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^INITD_DIR=.*|INITD_DIR=\"$INITD_DIR\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^LOG_DIR=.*|LOG_DIR=\"$LOG_DIR\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^STATE_DIR=.*|STATE_DIR=\"$STATE_DIR\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^PID_FILE=.*|PID_FILE=\"$PID_FILE\"|" "$OSE_SRC/$UNINSTALL_BIN"
sed -i "s|^DAEMON=.*|DAEMON=$OSE_SRC/$MAIN_BIN|" "$INITD_DIR/$OSE_BIN"
sed -i "s|^PIDFILE=.*|PIDFILE=$PID_FILE|" "$INITD_DIR/$OSE_BIN"
sed -i "s|^CONF=.*|CONF=$OSE_CONF/$OSE_CONF_FILE|" "$INITD_DIR/$OSE_BIN"

printf "[OK]\n" 
item_msg "Installed command: $OSE_SRC/$OSE_BIN"
item_msg "Installed scheduler: $OSE_SRC/$MAIN_BIN"
item_msg "Installed uninstaller: $OSE_SRC/$UNINSTALL_BIN"
item_msg "Init script: $INITD_DIR/$OSE_BIN"
item_msg "Config directory: $OSE_CONF"
item_msg "Log directory: $LOG_DIR"
item_msg "Installation log: $INSTALL_LOG_FILE"
item_msg "Main log: $MAIN_LOG_FILE"
item_msg "Backup log: $BACKUP_LOG_FILE"
item_msg "Restore log: $RESTORE_LOG_FILE"

generate_sftp_identity_key


# Configurable parameters
MANUAL_PARAMS="LDAPMASTERSERVER LDAPZIMBRADN LDAPZIMBRAPASS ADMINUSER ADMINPASS"
sed -i "s|^WORKDIR=|WORKDIR=\"$ZMBKPOSE_BKDIR\"|" "$OSE_CONF/$OSE_CONF_FILE"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SERVICE_USER "$ZMBKPOSE_USER"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" EXTRA_COMMAND_PATHS "$EXTRA_COMMAND_PATHS"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SCHEDULER_ENABLED yes
set_config_value "$OSE_CONF/$OSE_CONF_FILE" FULL_BACKUP_TIME "$FULL_BACKUP_TIME"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" INCREMENTAL_BACKUP_TIMES "$INCREMENTAL_BACKUP_TIMES"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" FULL_BACKUP_ARGS "-f"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" INCREMENTAL_BACKUP_ARGS "-i -t"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" BACKUP_KEEP_FULL "$BACKUP_KEEP_FULL"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" BACKUP_RETRY_COUNT "$BACKUP_RETRY_COUNT"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" BACKUP_RETRY_WAIT_SECONDS "$BACKUP_RETRY_WAIT_SECONDS"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SCHEDULER_SLEEP_SECONDS 30
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SCHEDULER_STATE_DIR "$STATE_DIR"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SCHEDULER_PID_FILE "$PID_FILE"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" MAIN_LOG_FILE "$MAIN_LOG_FILE"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" CHECK_ZIMBRA_ON_SERVICE_START yes
set_config_value "$OSE_CONF/$OSE_CONF_FILE" ZIMBRA_CONTROL "$ZIMBRA_DIR/bin/zmcontrol"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" REMOTE_COPY_ENABLED "$REMOTE_COPY_ENABLED"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" REMOTE_COPY_METHOD "$REMOTE_COPY_METHOD"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" RSYNC_ENABLED "$RSYNC_ENABLED"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" RSYNC_TARGET "$RSYNC_TARGET"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" RSYNC_OPTIONS "$RSYNC_OPTIONS"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" RSYNC_DELETE "$RSYNC_DELETE"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" RSYNC_BWLIMIT "$RSYNC_BWLIMIT"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" RSYNC_SSH_PORT "$RSYNC_SSH_PORT"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SFTP_TARGET "$SFTP_TARGET"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SFTP_PORT "$SFTP_PORT"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SFTP_IDENTITY_FILE "$SFTP_IDENTITY_FILE"
set_config_value "$OSE_CONF/$OSE_CONF_FILE" SFTP_OPTIONS "$SFTP_OPTIONS"
	cat<<-EOF

################################################################################
 I configured $OSE_CONF/$OSE_CONF_FILE whith :
    WORKDIR="$ZMBKPOSE_BKDIR"
    SERVICE_USER="$ZMBKPOSE_USER"
    EXTRA_COMMAND_PATHS="$EXTRA_COMMAND_PATHS"
    FULL_BACKUP_TIME="$FULL_BACKUP_TIME"
    INCREMENTAL_BACKUP_TIMES="$INCREMENTAL_BACKUP_TIMES"
    BACKUP_KEEP_FULL="$BACKUP_KEEP_FULL"
    BACKUP_RETRY_COUNT="$BACKUP_RETRY_COUNT"
    BACKUP_RETRY_WAIT_SECONDS="$BACKUP_RETRY_WAIT_SECONDS"
    CHECK_ZIMBRA_ON_SERVICE_START="yes"
    ZIMBRA_CONTROL="$ZIMBRA_DIR/bin/zmcontrol"
    REMOTE_COPY_ENABLED="$REMOTE_COPY_ENABLED"
    REMOTE_COPY_METHOD="$REMOTE_COPY_METHOD"
    RSYNC_ENABLED="$RSYNC_ENABLED"
    RSYNC_TARGET="$RSYNC_TARGET"
    SFTP_TARGET="$SFTP_TARGET"
 Change it if you decide to place the backup files elsewhere.
	EOF
show_sftp_public_key_hint

## Host dependent Configurable parameters
if $IS_A_ZIMBRA_HOST ;then
	cat<<-EOF

################################################################################
 If you want, I can try configure $OSE_CONF/$OSE_CONF_FILE
  with the following settings automatically detected:
   * LDAPMASTERSERVER=ldap://$ZIMBRA_ADDRESS:389
   * LDAPZIMBRADN=$ZIMBRA_LDAPDN
   * LDAPZIMBRAPASS=<detected>
	EOF
	if read_y_n_question "Do you like this script make these settings?" ;then
		[ -n "$ZIMBRA_ADDRESS" ] && \
			sed -i "s|^LDAPMASTERSERVER=|LDAPMASTERSERVER=ldap://$ZIMBRA_ADDRESS:389|" "$OSE_CONF/$OSE_CONF_FILE" && \
			MANUAL_PARAMS=$(echo "$MANUAL_PARAMS"|sed -r 's|\bLDAPMASTERSERVER\b||')
		[ -n "$ZIMBRA_LDAPDN" ] && \
			sed -i "s|^LDAPZIMBRADN=|LDAPZIMBRADN=\"$ZIMBRA_LDAPDN\"|" "$OSE_CONF/$OSE_CONF_FILE" && \
			MANUAL_PARAMS=$(echo "$MANUAL_PARAMS"|sed -r 's|\bLDAPZIMBRADN\b||')
		[ -n "$ZIMBRA_LDAPPASS" ] && \
			sed -i "s|^LDAPZIMBRAPASS=|LDAPZIMBRAPASS=\"$ZIMBRA_LDAPPASS\"|" "$OSE_CONF/$OSE_CONF_FILE" && \
			MANUAL_PARAMS=$(echo "$MANUAL_PARAMS"|sed -r 's|\bLDAPZIMBRAPASS\b||')
	fi
fi

# Manual configurations
cat<<-EOF

################################################################################
 You will need to configure the follow values manually  
  in $OSE_CONF/$OSE_CONF_FILE before to use $OSE_BIN:
$(for p in $MANUAL_PARAMS ;do echo "    * $p";done)
	EOF
if [ -n "$ZIMBRA_ADMUSERS" ]; then
  echo "The following users were found as administrators, and can be configured as ADMINUSER:"
  for u in $ZIMBRA_ADMUSERS;do echo "  * $u";done
fi

if command -v update-rc.d >/dev/null 2>&1;then
	if read_y_n_question "Enable $OSE_BIN service at boot?" ;then
		update-rc.d "$OSE_BIN" defaults
	fi
else
	echo "WARN: update-rc.d command not found. Service was installed but not enabled at boot."
fi

if read_y_n_question "Start $OSE_BIN service now?" ;then
	"$INITD_DIR/$OSE_BIN" start
fi

# We're done!
cat<<-EOF

################################################################################
	EOF

# Remember user for zmbkposev3 execution
cat<<-EOF

Note: --------------------------------------------------------------------------
 Remember execute $OSE_BIN using user "$ZMBKPOSE_USER", dependent commands 
  were checked using this user. 
--------------------------------------------------------------------------------
	EOF

if read_y_n_question "Install completed. Do you want to display the README.md file?" ;then
  if [ -c /dev/tty ];then
    less "$MYDIR/README.md" </dev/tty >/dev/tty
    echo "README.md displayed from $MYDIR/README.md"
  else
    less "$MYDIR/README.md"
  fi
fi

exit $ERR_OK
