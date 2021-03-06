#! /bin/bash
echo "[INFO] starting script..."
# Check for variable spelling, case-sensitive and variants
[[ ! -z "$gp_username" ]] && GP_USERNAME=$gp_username
[[ ! -z "$GP_USER" ]] && GP_USERNAME=$GP_USER
[[ ! -z "$user" ]] && GP_USERNAME=$user
[[ ! -z "$gp_password" ]] && GP_PASSWORD=$gp_password
[[ ! -z "$pass" ]] && GP_PASSWORD=$pass
[[ ! -z "$gp_host" ]] && GP_HOST=$gp_host
[[ ! -z "$nameserver" ]] && NAMESERVER=$nameserver
[[ ! -z "$nmap_target" ]] && NMAP_TARGET=$nmap_target
[[ ! -z "$smtp" ]] && SMTP=$smtp
[[ ! -z "$iftop" ]] && IFTOP=$iftop
[[ ! -z "$ftp" ]] && FTP=$ftp
[[ ! -z "$wget_syslog" ]] && WGET_SYSLOG=$wget_syslog
[[ ! -z "$wget_smtp" ]] && WGET_SMTP=$wget_smtp
[[ ! -z "$curl_pandb_url" ]] && CURL_PANDB_URL=$curl_pandb_url
[[ ! -z "$hipreport" ]] && HIPREPORT=$hipreport
[[ ! -z "$get_gp_certs" ]] && GET_GP_CERTS=$get_gp_certs
[[ ! -z "$timeout" ]] && TIMEOUT=$timeout
[[ ! -z "$minimal" ]] && MINIMAL=$minimal
[[ ! -z "$userlist" ]] && USERLIST=$userlist
[[ ! -z "$youtube_dl" ]] && YOUTUBE-DL=$youtube_dl

if [ "$GP_DISABLED" = "true" ]; then
echo "Bypassing GP..."
./scripts/gp-disabled.sh
exit
fi


COMPOSE_CERT_DIR="certificates-compose/"
if [ -d "$COMPOSE_CERT_DIR" ]; then
  echo "Using client certificates from docker-compose"
  cp --force certificates-compose/docker_machine_cert.crt . 2>/dev/null
  cp --force certificates-compose/docker_machine_cert.key . 2>/dev/null
else
  cp --force certificates/docker_machine_cert.crt . 2>/dev/null
  cp --force certificates/docker_machine_cert.key . 2>/dev/null
fi

cp --force userlist/userlist.csv . 2>/dev/null

if [ "$USERLIST" = "true" ]; then
echo "Using credentials from userlist.csv"
CREDENTIAL=$(shuf -n 1 userlist.csv)
GP_USERNAME=$(echo $CREDENTIAL | grep -m 1 -Eo [^,]+ | head -n 1)
GP_PASSWORD=$(echo $CREDENTIAL | grep -m 1 -Eo [^,]+ | tail -n 1)
fi

OPENCONNECT_LOG="logs/openconnect.log"
OPENCONNECT_ERROR_AUTHFAIL="(: auth-failed)|(Authentication failure)"
OPENCONNECT_ERROR_CLIENTCERTIFICATE="Valid client certificate is required"
OPENCONNECT_ERROR_PRIVILEGED="Failed to bind local tun device (TUNSETIFF): Operation not permitted"
OPENCONNECT_ERROR_MULTIPLEGATEWAYS="[2-9] gateway servers available:"
OPENCONNECT_ERROR_DNSRESOLUTION="getaddrinfo failed for host"
OPENCONNECT_ERROR_CERTIFICATE="Enter 'yes' to accept"
OPENCONNECT_ERROR_TLSFATALALERT="A TLS fatal alert has been received"

if [ "$MINIMAL" = "true" ]; then
		NMAP="false"
		SMTP="false"
		FTP="false"
		WGET_FTP="false"
		WGET_SMTP="false"
		WGET_SYSLOG="false"
		CURL_PANDB_URL="false"
		BITTORRENT="false"
		YOUTUBE_DL="false"
		echo "[INFO] Minimal ENV true, skipping all non-HTTP"
fi

# Check if HIP report should be used
if [ "$HIPREPORT" = "true" ]; then
HIPREPORT="--csd-wrapper scripts/hipreport.sh"
  sleep 1
  else
echo "[INFO] Skipping HIP report"
  HIPREPORT=""
fi

if [ "$GP_USERNAME" = "CHANGE_ME" ]; then
echo "[WARN] Username missing"
echo "Enter username and press [ENTER]"
read GP_USERNAME
else
echo "[INFO] Username: $GP_USERNAME"
fi
if [ "$GP_PASSWORD" = "CHANGE_ME" ]; then
echo "[WARN] Password missing"
echo "Enter password and press [ENTER]"
read -s GP_PASSWORD
else
echo "[INFO] Password filled out"
fi
if [ "$GP_HOST" = "CHANGE_ME" ]; then
echo "[WARN] GP host missing"
echo "Enter GlobalProtect Portal/Gateway and press [ENTER]"
read GP_HOST
else
echo "[INFO] GP host: $GP_HOST"
fi

echo $GP_PASSWORD > gp_password.txt

# Split GP server hostname and port in different vars
HOST="$(echo $GP_HOST | cut -d: -f1)"
PORT="$(echo $GP_HOST | cut -d: -f2 -s)"
if [ -z "$PORT" ]; then
                PORT=443
                sleep 1
fi

if [ "$GET_GP_CERTS" = "true" ]; then
# Get all certs in chain, from GP host, install as CA
nohup openssl s_client -showcerts -verify 5 -connect ${HOST}:${PORT} < /dev/null | awk '/BEGIN/,/END/{ if(/BEGIN/){a++}; out="certificates-gp/cert"a".crt"; print >out}'
cp certificates-gp/*.crt /usr/local/share/ca-certificates/ 2>/dev/null
fi
echo "[INFO] Updating CA certificates*"
cp certificates/*.crt /usr/local/share/ca-certificates/ 2>/dev/null
cp certificates/*.cert /usr/local/share/ca-certificates/ 2>/dev/null
chmod 644 /usr/local/share/ca-certificates/* 2>/dev/null && update-ca-certificates 2>/dev/null | sed 's/.*/[INFO] &/'
# Set Python Request to use local cert store
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

echo "[INFO] Connecting..."
openconnect --background --protocol=gp $GP_HOST --user=$GP_USERNAME --passwd-on-stdin < gp_password.txt --certificate=docker_machine_cert.crt --sslkey=docker_machine_cert.key $HIPREPORT --verbose &> logs/openconnect.log

cp gp_password.txt gp_stdin_merge.txt
# Stage 1 of tunnel checks
sleep 2
OPERSTATE=$(ifconfig tun0 | grep "UP,")
if [ -z "$OPERSTATE" ]; then
		if grep -Eq "$OPENCONNECT_ERROR_CERTIFICATE" "$OPENCONNECT_LOG"; then #Check for bad gateway cert
		 echo "yes" >>gp_stdin_merge.txt
		fi
		if grep -Eq "$OPENCONNECT_ERROR_MULTIPLEGATEWAYS" "$OPENCONNECT_LOG"; then
         echo "[INFO] Multiple gateways detected. Will retry using first gateway on list"
		 awk '/gateway servers available:/{getline; print}' logs/openconnect.log | awk -F"[()]" '{print $2}' >>gp_stdin_merge.txt
		fi
		if grep -Eq "$OPENCONNECT_ERROR_CERTIFICATE" "$OPENCONNECT_LOG"; then #Run check again, in case gateway cert is bad
		 echo "yes" >>gp_stdin_merge.txt
		fi
fi

OPERSTATE=$(ifconfig tun0 | grep "UP,")
if [ -z "$OPERSTATE" ]; then
openconnect --background --protocol=gp $GP_HOST --user=$GP_USERNAME --passwd-on-stdin < gp_stdin_merge.txt --certificate=docker_machine_cert.crt --sslkey=docker_machine_cert.key $HIPREPORT --verbose &> logs/openconnect.log
fi

#Stage 2 of tunnel checks
sleep 2
OPERSTATE=$(ifconfig tun0 | grep "UP,")
if [ -z "$OPERSTATE" ]; then
    echo "[WARN] Interface tun0 is DOWN. Checking for known errors"
		if grep -Eq "$OPENCONNECT_ERROR_AUTHFAIL" "$OPENCONNECT_LOG"; then
         echo -e "\e[31m[ERROR] Authentication failed, verify user credentials\e[0m"
        fi
         if grep -q "$OPENCONNECT_ERROR_DNSRESOLUTION" "$OPENCONNECT_LOG"; then
         echo -e "\e[31m[ERROR] Could not resolve host. Check DNS"
         cat "$OPENCONNECT_LOG" | grep "$OPENCONNECT_ERROR_DNSRESOLUTION"
        fi
		if grep -q "$OPENCONNECT_ERROR_CLIENTCERTIFICATE" "$OPENCONNECT_LOG"; then
         echo -e "\e[31m[ERROR] Machine certificate missing\e[0m"
        fi
		if grep -q "$OPENCONNECT_ERROR_TLSFATALALERT" "$OPENCONNECT_LOG"; then
         echo -e "\e[31m[ERROR] Error in TLS stream. Possibly client certificate issue	\e[0m"
        fi		
		if grep -q "$OPENCONNECT_ERROR_PRIVILEGED" "$OPENCONNECT_LOG"; then
         echo -e "\e[31m[ERROR] Could not create tun0 device. Did you remember to use --privileged in docker run command?\e[0m"
        fi
	echo -e "\e[96m" && tail --verbose -n 10 logs/openconnect.log | sed 's/.*/[DEBUG] &/' && echo -e "\e[0m"		
	echo -e "[INFO] Exiting container"
	exit 1
else
        echo "[INFO] Interface tun0 is UP. Proceeding"
fi

# Write connection info
cat logs/openconnect.log  | grep -E "(^[Cc]onnected [to|as].+)|(^ESP tunnel.+)" > logs/console_connected.txt
sed 's/^/[INFO] /' logs/console_connected.txt

if [ "$NMAP" = "true" ]; then
		NAMESERVER="$(egrep -o -m 1 '[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}' /etc/resolv.conf)"
		echo "[INFO] Starting nmap to nameserver $NAMESERVER"
		nohup nmap -v -A $NAMESERVER &> logs/nmap_nameserver &
else
		echo "[INFO] Skipping nmap nameserver"
		sleep 1
fi


if [ "$SMTP" = "true" ]; then
		echo "[INFO] Starting wget/smtp in background"
		nohup ./scripts/wget_swaks.sh &> logs/wget_swaks.log &
		sleep 1
else
		echo "[INFO] Skipping wget/SMTP"
		sleep 1
fi

if [ "$WGET_SYSLOG" = "true" ]; then
		echo "[INFO] Starting wget/syslog in background"
		nohup ./scripts/wget_syslog.sh &> logs/wget_syslog.log &
		sleep 1
else
		echo "[INFO] Skipping wget/syslog"
		sleep 1
fi

if [ "$WGET_FTP" = "true" ]; then
		echo "[INFO] Starting wget/FTP download in background"
		nohup ./scripts/wget_ftp.sh &> logs/wget_ftp.log &
		sleep 1
else
		echo "[INFO] Skipping wget/FTP"
		sleep 1
fi

if [ "$YOUTUBE_DL" = "true" ]; then
		echo "[INFO] Starting youtube-dl in background"
		nohup ./scripts/youtube-dl.sh &> logs/youtube-dl.log &
		sleep 1
else
		echo "[INFO] Skipping youtube-dl"
		sleep 1
fi

if [ "$CURL_PANDB_URL" = "true" ]; then
		echo "[INFO] Starting PAN-DB URL Filtering category curl"
		nohup ./scripts/curl_pandb_url.sh &> logs/curl_pandb_url.log &
		sleep 1
else
		echo "[INFO] Skipping PAN-DB curl"
		sleep 1
fi

if [ -z "$NMAP_TARGET" ]; then
		sleep 1
else
		echo "[INFO] nmap_target specified. Starting nmap scan"
		nohup nmap -v -A $NMAP_TARGET &> logs/nmap_target.log &
		sleep 1
fi

if [ "$BITTORRENT" = "true" ]; then
		echo "[INFO] Starting bittorrent client"
		transmission-daemon --config-dir transmission-daemon/ --logfile logs/transmission-daemon.log
		sleep 1
else
		echo "[INFO] Skipping bittorrent"
		sleep 1
fi

if [ "$IFTOP" = "true" ]; then
		echo "[INFO] Starting webcrawl in background, iftop -i tun0 in foreground"
		echo "[INFO] Timeout value $TIMEOUT"
		sleep 4
		nohup python3 scripts/noisy/noisy.py --config scripts/noisy/config.json --timeout $TIMEOUT &
		iftop -i tun0 -P
		echo "[INFO] Timeout reached. Killing VPN"
		pkill -f openconnect
		sleep 1
else
		echo "[INFO] Starting webcrawl in foreground. Timeout value $TIMEOUT"
		sleep 1
		python3 scripts/noisy/noisy.py --config scripts/noisy/config.json --timeout $TIMEOUT
		echo "[INFO] Timeout reached. Killing VPN"
		pkill -f openconnect
		sleep 1
fi