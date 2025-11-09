WI_FI_TITLE="Wi-Fi"
DISK_TITLE="Disk"

#-------------- whiptail functions --------------
CHOICE=""
MENU_ITEMS=()
EXIT_STATUS=0

# "${ARGUMENT[@]}"
read_menu_options() {
  MENU_ITEMS=()
  for ITEM in $1; do
    MENU_ITEMS+=("$ITEM" "")
  done
}

#title text
menu() {
  CHOICE=$(whiptail --title "$1" --menu "$2" 20 60 12 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
  EXIT_STATUS=$?
}

#title text
message() {
  whiptail --title "$1" --msgbox "$2" 7 50
}

#title text
critical_error() {
  message "$1" "$2"
  EXIT_STATUS=1
}

#title text
password() {
  CHOICE=$(whiptail --title "$1" --passwordbox "$2" 8 78  3>&1 1>&2 2>&3)
  EXIT_STATUS=$?
}

#-------------- Network --------------
connect_wifi() {
  if check_ping; then
    return 0
  fi

  #power on wifi
  local NETWORK_DEVICES=$(networkctl list | awk 'NR>1 && NF > 0 && $0 !~ /links listed/ {print $2}')
  if [ -z "$NETWORK_DEVICES" ]; then
    critical_error "$WI_FI_TITLE" "Error. Can't find network devices"
    return 1
  fi

  read_menu_options "${NETWORK_DEVICES[@]}"
  menu "$WI_FI_TITLE" "Select network device:"
  local WIFI_DEVICE="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  if ! networkctl up "$WIFI_DEVICE"; then
    message "$WI_FI_TITLE" "Can't switch on device: $WIFI_DEVICE"
    return 1
  fi

  #wifi name
  local NETWORKS=$(iw dev "$WIFI_DEVICE" scan | grep "SSID:" | awk 'NF>0 {print $2}')
  if [ -z "$NETWORKS" ]; then
      message "$WI_FI_TITLE" "Error. Can't find networks"
      return 1
  fi

  read_menu_options "${NETWORKS[@]}"
  menu "$WI_FI_TITLE" "Select network:"
  local WIFI_NAME="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    EXIT_STATUS=0
    return 1
  fi

  #password
  password "$WI_FI_TITLE" "Enter password for the network:"
  local WIFI_PASSWORD="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
      EXIT_STATUS=0
      return 1
  fi

  #connection
  if ! iwctl --passphrase "$WIFI_PASSWORD" station "$WIFI_DEVICE" connect "$WIFI_NAME"; then
    return 1
  fi

  local i=0
  {
    echo $i
    while ! ip addr show "$WIFI_DEVICE" | grep -q "inet "; do
      sleep 1

      ((i++))
      echo $((i * 10))
      if (( i > 10 )); then
        return 1
      fi
    done

    echo 100
  } | whiptail --gauge "Connecting to Wi-Fi..." 6 50 0
}

check_ping() {
  if ! ping -c 3 archlinux.org >> /dev/null; then
    return 1
  fi
}

#-------------- Disk --------------
format_disk() {
  echo "test"
}

#Check network
while ! connect_wifi; do
  if [ $EXIT_STATUS == 1 ]; then
    exit -1
  fi
  message "$WI_FI_TITLE" "Connection has not been established."
done

