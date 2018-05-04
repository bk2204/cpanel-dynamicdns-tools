#!/bin/sh
# cpanel - src/tools/cpanel-dynamic-dns.sh        Copyright(c) 2012 cPanel, Inc.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# Tested Configurations
# RedHat EL 4,5,6
# CentOS 4,5,6
# OpenWRT (w/openssl installed)

# Configuration should be done in the configuration files
# or it can be manually set here

#
# CONTACT_EMAIL is the email address that will be contacted upon failure
#
CONTACT_EMAIL=""

#
# DOMAIN and SUBDOMAIN are the domain that should get its A entry updated
# SUBDOMAIN can be left blank if you wish to update the root domain
# SUBDOMAINLIST may contain a space separated list of SUBDOMAINS
# SUBDOMAINLIST takes precedence over SUBDOMAIN
#
DOMAIN=""
SUBDOMAIN=""
SUBDOMAINLIST=""

#
# CPANEL_SERVER is the hostname or ip address to connect to
#
CPANEL_SERVER=""

#
# CPANEL_USER and CPANEL_PASS are the username and password for your
# cPanel Account
#
CPANEL_USER=""
CPANEL_PASS=""

#
#  QUIET supresses all information messages (not errors)
#  set to 0 or 1
#
QUIET=""

# Program starts here
setup_vars () {
	VERSION="2.1"
	APINAME=""
	PARENTPID=$$
	HOMEDIR=`echo ~`
	LAST_CONNECT_HOST=""
	FAILURE_NOTIFY_INTERVAL="14400"
	PERMIT_ROOT_EXECUTION="0"
	NOTIFY_FAILURE="1"
	TIMEOUT="120"
	BASEDIR="cpdyndns"
}
load_config () {
	if [ -e "/etc/$BASEDIR.conf" ]; then
		chmod 0600 /etc/$BASEDIR.conf
		. /etc/$BASEDIR.conf
		CFGMESSAGE1="== /etc/$BASEDIR.conf is being used for configuration"
	else
		CFGMESSAGE1="== /etc/$BASEDIR.conf does not exist"
	fi
	if [ -e "$HOMEDIR/etc/$BASEDIR.conf" ]; then
		chmod 0600 $HOMEDIR/etc/$BASEDIR.conf
		. $HOMEDIR/etc/$BASEDIR.conf
		CFGMESSAGE2="== $HOMEDIR/etc/$BASEDIR.conf is being used for configuration"
	else
		CFGMESSAGE2="== $HOMEDIR/etc/$BASEDIR.conf does not exist"
	fi
	if [ -n "$SUBDOMAINLIST" ]; then
		SUBDOMAINARRAY=$SUBDOMAINLIST
	else
		SUBDOMAINARRAY="$SUBDOMAIN"
	fi
}
msg () {
	if [ "$QUIET" != "1" ]; then
		echo $@
	fi
}
banner () {
	msg "=="
	msg "== cPanel Dyanmic DNS Updater $VERSION"
	msg "=="
	msg "==  Updating domain $SUBDOMAINLIST in $DOMAIN"
	msg "=="
	msg $CFGMESSAGE1
	msg $CFGMESSAGE2
	msg "=="
}
setup_config_vars () {
	if [ "$SUBDOMAIN" = "" ]; then
		APINAME="$DOMAIN."
	else
		APINAME="$SUBDOMAIN"
	fi
	LAST_RUN_FILE="$HOMEDIR/.$BASEDIR/$SUBDOMAIN.$DOMAIN.lastrun"
	LAST_FAIL_FILE="$HOMEDIR/.$BASEDIR/$SUBDOMAIN.$DOMAIN.lastfail"
}
create_dirs () {
	if [ ! -e "$HOMEDIR/.$BASEDIR" ]; then
		mkdir -p "$HOMEDIR/.$BASEDIR"
		chmod 0700 "$HOMEDIR/.$BASEDIR"
	fi
}
exit_timeout () {
	ALARMPID=""
	msg "The operation timed out while connecting to $LAST_CONNECT_HOST"
	notify_failure "Timeout" "Connection Timeout" "Timeout while connecting to $LAST_CONNECT_HOST"
	exit
}
setup_timeout () {
	(sleep $TIMEOUT; kill -ALRM $PARENTPID) &
	ALARMPID=$!
	trap exit_timeout 14
}
terminate () {
	if [ "$ALARMPID" != "" ]; then
		kill $ALARMPID
	fi
	exit
}
fetch_myaddress () {
	msg "Determining IP Address..."
	LAST_CONNECT_HOST="myip.cpanel.net"
	MYADDRESS=`printf "GET /v1.0/ HTTP/1.0\r\nHost: myip.cpanel.net\r\nConnection: close\r\n\r\n" | openssl s_client -quiet -connect myip.cpanel.net:443 2>/dev/null | tail -1`
	msg "MYADDRESS=$MYADDRESS"
	if [ "$MYADDRESS" = "" ]; then
		msg "Failed to determine IP Address (via https://www.cpanel.net/myip/)"
		terminate
	fi
}
load_last_run () {
	if [ -e "$LAST_RUN_FILE" ]; then
		. $LAST_RUN_FILE
	fi
}
exit_if_last_address_is_current () {
	if [ "$LAST_ADDRESS" = "$MYADDRESS" ]; then
		msg "Last update was for $LAST_ADDRESS, and address has not changed."
		msg "If you want to force an update, remove $LAST_RUN_FILE"
		terminate
	fi
}
generate_auth_string () {
	AUTH_STRING=`echo -n "$CPANEL_USER:$CPANEL_PASS" | openssl enc -base64`
}
call_cpanel_api () {
	FUNCTION=$1
	PARAMETERS=$2
	msg "Calling cpanel api function '$FUNCTION' with parameters '$PARAMETERS' for $DOMAIN...."
	LAST_CONNECT_HOST=$CPANEL_SERVER
	REQUEST="GET /json-api/cpanel?cpanel_jsonapi_module=ZoneEdit&cpanel_jsonapi_func=$FUNCTION&cpanel_jsonapi_apiversion=2&domain=$DOMAIN$PARAMETERS HTTP/1.0\r\nConnection: close\r\nAuthorization: Basic $AUTH_STRING\r\nUser-Agent: cpanel-dynamic-dns.sh $VERSION\r\n\r\n\r\n"
	REQUEST_RESULTS=`printf "$REQUEST" | openssl s_client -quiet -connect $CPANEL_SERVER:2083 2>/dev/null`
	check_results_for_error "$REQUEST_RESULTS" "$REQUEST"
}
fetch_zone () {
	call_cpanel_api 'fetchzone'
	ZONE="$REQUEST_RESULTS"
}
get_lines_for_subdomain () {
	AWKPROGRAM="BEGIN { FS=\"[{}]\" } { for (f = 1; f <= NF; f++) { if (index(\$f, \"\\\"type\\\":\\\"A\\\"\") == 0) continue; if (index(\$f, \"\\\"name\\\":\\\"$SUBDOMAIN.$DOMAIN.\\\"\") == 0) continue; m = match(\$f, /\"line\":[0-9]+/); if (m) print substr(\$f, RSTART+7, RLENGTH-7) } }"
	LINES=`echo "$ZONE" | awk "$AWKPROGRAM"`
}
remove_duplicate_lines () {
	FIRSTLINE=""
	REMOVED=0
	for LINE in $LINES; do
		if [ "$FIRSTLINE" = "" ]; then
			FIRSTLINE="$LINE"
			continue
		fi
		call_cpanel_api 'remove_zone_record' "&line=$LINE"
		REMOVED=1
	done
	if [ $REMOVED -eq 0 ]; then
		msg "No duplicates found..."
	fi
}
get_cpanel_address () {
	AWKPROGRAM="BEGIN { FS=\"[{}]\" } { for (f = 1; f <= NF; f++) { if (index(\$f, \"\\\"type\\\":\\\"A\\\"\") == 0) continue; if (index(\$f, \"\\\"name\\\":\\\"$SUBDOMAIN.$DOMAIN.\\\"\") == 0) continue; m = match(\$f, /\"address\":\"[0-9\\.]+\"/); if (m) { print substr(\$f, RSTART+11, RLENGTH-12); break } } }"
	CPANELADDRESS=`echo "$ZONE" | awk "$AWKPROGRAM"`
}
update_record () {
	if [ "$FIRSTLINE" = "" ]; then
		msg "Adding record for $SUBDOMAIN.$DOMAIN."
		call_cpanel_api 'add_zone_record' "&name=$APINAME&type=A&address=$MYADDRESS&ttl=300"
		return
	fi
	if [ "$CPANELADDRESS" = "$MYADDRESS" ]; then
		msg "No need to update record. $SUBDOMAIN.$DOMAIN's address is $CPANELADDRESS"
		echo "LAST_ADDRESS=\"$MYADDRESS\"" > $LAST_RUN_FILE
		return
	fi
	call_cpanel_api 'edit_zone_record' "&Line=$FIRSTLINE&domain=$DOMAIN&name=$APINAME&type=A&address=$MYADDRESS&ttl=300"
	if [ "`echo $REQUEST_RESULTS | grep 'newserial'`" ]; then
		msg "Record update was ok."
	else
		msg "There was an error updating the record."
		msg "$REQUEST_RESULTS"
	fi
}
process_subdomain () {
	setup_config_vars
	get_lines_for_subdomain
	remove_duplicate_lines
	get_cpanel_address
	update_record
}
check_results_for_error () {
	if [ "`echo $REQUEST_RESULTS | grep '"status":1'`" ]; then
		msg "Success."
	else
		MSG=`echo $REQUEST_RESULTS | awk 'match($0, /"reason":"[^"]\+"/) { print substr($0, RSTART+10, RLENGTH-11) }'`
		STATUSMSG=`echo $REQUEST_RESULTS | awk 'match($0, /"statusmsg":"[^"]\+"/) { print substr($0, RSTART+13, RLENGTH-14) }'`
		if [ "$MSG" = "" ]; then
			MSG="Unknown Error"
			if [ "$STATUSMSG" = "" ]; then
				STATUSMSG="Please make sure you have the zoneedit, or simplezone edit permission on your account."
			fi
		fi
		msg "Request failed with error: $MSG ($STATUSMSG)\nREQUEST_RESULTS: $REQUEST_RESULTS"
		notify_failure "$MSG" "$STATUSMSG" "$REQUEST_RESULTS" "$REQUEST"
		terminate
	fi
}
notify_failure () {
	CURRENT_TIME=`date +%s`
	LAST_TIME=0
	if [ -e "$LAST_FAIL_FILE" ]; then
		. $LAST_FAIL_FILE
	fi
	TIME_DIFF=`expr $CURRENT_TIME - $LAST_TIME`
	if [ "$CONTACT_EMAIL" = "" ]; then
		msg "No contact email address was set.  Cannot send failure notification."
		return
	fi
	if [ $TIME_DIFF -gt $FAILURE_NOTIFY_INTERVAL ]; then
		echo "LAST_TIME=$CURRENT_TIME" > $LAST_FAIL_FILE
		SUBJECT="Failed to update dynamic DNS for $SUBDOMAIN.$DOMAIN. on $CPANEL_SERVER : $MSG ($STATUMSG)"
		if [ -e "/bin/mail" ]; then
			msg "sending email notification of failure."
			echo "Status Message: $STATUSMSG\nThe full response was: $REQUEST_RESULTS" | /bin/mail -s "$SUBJECT" $CONTACT_EMAIL
		else
			msg "/bin/mail is not available, cannot send notification of failure."
		fi
	else
		msg "skipping notification because a notication was sent $TIME_DIFF seconds ago."
	fi
}
check_for_root () {
	if [ "$PERMIT_ROOT_EXECUTION" = "1" ]; then
		return
	fi
	if [ "`id -u`" = "0" ]; then
		echo "You should not run this script as root if possible"
		echo "If you really want to run as root please run"
		echo "echo \"PERMIT_ROOT_EXECUTION=1\" >> /etc/$BASEDIR.conf"
		echo "and run this script again"
		terminate
	fi
}
check_config () {
	if [ "$CONTACT_EMAIL" = "" ]; then
		echo "= Warning: no email address set for notifications"
	fi
	if [ "$CPANEL_SERVER" = "" ]; then
		echo "= Error: CPANEL_SERVER must be set in a configuration file"
		exit
	fi
	if [ "$DOMAIN" = "" ]; then
		echo "= Error: DOMAIN must be set in a configuration file"
		exit
	fi
	if [ "$CPANEL_USER" = "" ]; then
		echo "= Error: CPANEL_USER must be set in a configuration file"
		exit
	fi
	if [ "$CPANEL_PASS" = "" ]; then
		echo "= Error: CPANEL_PASS must be set in a configuration file"
		exit
	fi
	if [ "$DOMAIN" = "$CPANEL_SERVER" ] && [ "$SUBDOMAIN" = "" ] && [ "$SUBDOMAINLIST" = "" ]; then
		echo "= Error: Must not change the CPANEL_SERVER's IP address."
		exit
	fi
}

setup_vars
setup_timeout
load_config
setup_config_vars
banner
check_for_root
check_config
fetch_myaddress
create_dirs
load_last_run
exit_if_last_address_is_current
generate_auth_string
fetch_zone
for SUBDOMAIN in $SUBDOMAINARRAY; do
    process_subdomain
done
if [ -z "$SUBDOMAINARRAY" ]; then
    SUBDOMAIN=""
    process_subdomain
fi
terminate
