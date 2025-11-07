WI_FI_TITLE="Wi-Fi"

#-------------- echo --------------
yecho() {
  echo -e "\e[33m$1\e[0m"
}

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
  if ! power_on_iwctl "adapter"; then
    return 1
  fi

  if ! power_on_iwctl "device"; then
    if [ $EXIT_STATUS -eq 1 ]; then
        EXIT_STATUS=0
    fi
    return 1
  fi
  local WIFI_DEVICE="$CHOICE"

  #wifi name
  iwctl station "$WIFI_DEVICE" scan >> /dev/null
  local ENTRIES=$(iwctl station "$WIFI_DEVICE" get-networks | awk 'NR>4 { if (NF > 3) print $2; else print $1 }' | sed '/^$/d')
  if [ -z "$ENTRIES" ]; then
      message "$WI_FI_TITLE" "Error. Can't find networks"
      return 1
  fi

  read_menu_options "${ENTRIES[@]}"
  menu "$WI_FI_TITLE" "Select network:"
  local WIFI_NAME="$CHOICE"
  if [ $EXIT_STATUS -eq 1 ]; then
    EXIT_STATUS=0
    return 1
  fi

  #password
  password "$WI_FI_TITLE" "Enter password for the network:"
  local WIFI_PASSWORD="$CHOICE"
  if [ $EXIT_STATUS -eq 1 ]; then
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
  clear
}

check_ping() {
  if ! ping -c 3 archlinux.org >> /dev/null; then
    return 1
  fi
}

#adapter/device
power_on_iwctl() {
    local ENTRIES=$(iwctl "$1" list | awk 'NR>3 {print $2}' | sed '/^$/d')
    if [ -z "$ENTRIES" ]; then
      critical_error "$WI_FI_TITLE" "Critical error. Can't find $1"
      return 1
    fi

    read_menu_options "${ENTRIES[@]}"
    menu "$WI_FI_TITLE" "Select $1:"
    if [ $EXIT_STATUS -eq 1 ]; then
        return 1
    fi

    if ! iwctl "$1" "$CHOICE" set-property Powered on >> /dev/null; then
      return 1
    fi
}

#Check network
while ! connect_wifi; do
  if [ $EXIT_STATUS -eq 1 ]; then
    exit -1
  fi
  message "$WI_FI_TITLE" "Connection has not been established."
done

