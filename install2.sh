WI_FI_TITLE="Wi-Fi"
DISK_TITLE="Disk"

#0 - true; 1 - false
DISK_ENCRYPT=1
DISK_SSD=1

#-------------- utils --------------
#0/1
isTrue() {
  if [ $1 == 0 ]; then
    echo "true"
  else
    echo "false"
  fi
}

is_nvme() {
  [[ "$1" == *nvme* ]]
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
  whiptail --title "$1" --msgbox "$2" 7 60
}

#title text
critical_error() {
  message "$1" "$2"
  EXIT_STATUS=1
}

#title text
passwordbox() {
  CHOICE=$(whiptail --title "$1" --passwordbox "$2" 8 80 3>&1 1>&2 2>&3)
  EXIT_STATUS=$?
}

#title text
yesno() {
  CHOICE=$(whiptail --title "$1" --yesno "$2" 7 60 3>&1 1>&2 2>&3; echo $?)
}

#title text
inputbox() {
  CHOICE=$(whiptail --title "$1" --inputbox "$2" 8 80 3>&1 1>&2 2>&3)
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
    critical_error "$WI_FI_TITLE" "ERROR. Can't find network devices"
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
      message "$WI_FI_TITLE" "ERROR. Can't find networks"
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
  passwordbox "$WI_FI_TITLE" "Enter password for the network:"
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
  if ! ping -c 3 archlinux.org; then
    return 1
  fi
}

#-------------- Disk --------------
format_disk() {
  #disk name
  MENU_ITEMS=()
  while read -r NAME SIZE MODEL; do
    MENU_ITEMS+=("$NAME" "$SIZE $MODEL")
  done < <(lsblk -do NAME,SIZE,MODEL | tail -n +2)

  if [ -z "$MENU_ITEMS" ]; then
    critical_error "$DISK_TITLE" "ERROR. Can't find disks"
    return 1
  fi

  menu "$DISK_TITLE" "Choose disk for system:"
  local DISK_NAME="$CHOICE"
  local DISK_PATH="/dev/$DISK_NAME"
  if [ $EXIT_STATUS == 1 ]; then
      return 1
  fi

  #ssd optimization
  yesno "$DISK_TITLE" "Is it SSD?"
  DISK_SSD=$CHOICE

  #encryption
  yesno "$DISK_TITLE" "Do you want to use full disk encryption?"
  DISK_ENCRYPT=$CHOICE

  #swap size
  local SWAP_SIZE=$(whiptail --title "$DISK_TITLE" --inputbox "
  Choose size for swap in GB:

  Recommendations:
  |    RAM    |     Swap     | Swap with hibernation (not suspension) |
  ---------------------------------------------------------------------
  |  < 4 GB   |    2 * RAM   |             3 * RAM                    |
  ---------------------------------------------------------------------
  | 4 - 8 GB  |     RAM      |             2 * RAM                    |
  ---------------------------------------------------------------------
  | 8 - 32 GB |  At least 4  |            1.5 * RAM                   |
  ---------------------------------------------------------------------
  |   32+ GB  |  At least 4  |   Just dont. Take pity on your disk    |
  ---------------------------------------------------------------------
  " 22 80 3>&1 1>&2 2>&3)
  EXIT_STATUS=$?
  if [ $EXIT_STATUS == 1 ]; then
    EXIT_STATUS=0
    return 1
  fi

  #root size
  inputbox "$DISK_TITLE" "Choose size for root in GB (50 - 100):"
  local ROOT_SIZE=$CHOICE
  if [ $EXIT_STATUS == 1 ]; then
    EXIT_STATUS=0
    return 1
  fi

  #confirmation
  local ENCRYPT_TRUE_FALSE=$(isTrue $DISK_ENCRYPT)
  local SSD_TRUE_FALSE=$(isTrue $DISK_SSD)

  CHOICE=$(whiptail --title "$DISK_TITLE" --yesno "
  Disk: $DISK_NAME
  Swap size: $SWAP_SIZE
  Root size: $ROOT_SIZE
  SSD: $SSD_TRUE_FALSE
  Encryption: $ENCRYPT_TRUE_FALSE

  Data on disk will be erased. Continue?
  " 14 60 3>&1 1>&2 2>&3; echo $?)
  if [ $CHOICE != 0 ]; then
      EXIT_STATUS=0
      return 1
  fi

  #process
  #deactivate all LVMs if exist or wipefs will not work
  vgchange -an

  #erasing
  if ! {
    wipefs -a "$DISK_PATH" &&
    sgdisk --zap-all "$DISK_PATH"
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't erase disk"
    return 1
  fi

  #partitioning
  if ! {
    parted -s "$DISK_PATH" mklabel gpt &&
    #EFI 1Gb
    parted -s "$DISK_PATH" mkpart ESP fat32 1MiB 1025MiB &&
    parted -s "$DISK_PATH" set 1 boot on &&
    #LUKS\LVM rest
    parted -s "$DISK_PATH" mkpart primary 1025MiB 100%
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't create partitions"
    return 1
  fi

  #creating LVM and LUKS optional
  local EFI_PART=""
  local ROOT_PART=""
  if is_nvme "$DISK_PATH"; then
    EFI_PART="${DISK_PATH}p1"
    ROOT_PART="${DISK_PATH}p2"
  else
    EFI_PART="${DISK_PATH}1"
    ROOT_PART="${DISK_PATH}2"
  fi

  #LUKS
  if [ $DISK_ENCRYPT == 0 ]; then
    local CRYPT_NAME="cryptlvm"
    if ! {
      cryptsetup luksFormat "$ROOT_PART" &&
      cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue --persistent open "$ROOT_PART" "$CRYPT_NAME"
    }; then
      critical_error "$DISK_TITLE" "ERROR. Can't create encrypted volume"
      return 1
    fi
    ROOT_PART="/dev/mapper/$CRYPT_NAME"
  fi

  #LVM
  local VG_NAME="vg0"
  if ! {
    pvcreate "$ROOT_PART" &&
    vgcreate "$VG_NAME" "$ROOT_PART" &&
    lvcreate -L "$SWAP_SIZE"G "$VG_NAME" -n swap &&
    lvcreate -L "$ROOT_SIZE"G "$VG_NAME" -n root &&
    lvcreate -l 100%FREE "$VG_NAME" -n home;
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't create logical volume"
    return 1
  fi

  #formatting
  local VG_PART="/dev/$VG_NAME"
  local VG_SWAP_PART="$VG_PART/swap"
  local VG_ROOT_PART="$VG_PART/root"
  local VG_HOME_PART="$VG_PART/home"
  if ! {
    mkfs.fat -F32 "$EFI_PART" &&
    mkswap "$VG_SWAP_PART" &&
    mkfs.ext4 "$VG_ROOT_PART" &&
    mkfs.ext4 "$VG_HOME_PART";
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't format partitions"
    return 1
  fi

  #mounting
  local MOUNT_OPTIONS="errors=remount-ro"
  if [ $DISK_SSD == 0 ]; then
    MOUNT_OPTIONS="noatime,errors=remount-ro"
  fi

  if ! {
    mount -o "$MOUNT_OPTIONS" "$VG_ROOT_PART" /mnt &&
    mkdir /mnt/home &&
    mount -o "$MOUNT_OPTIONS" "$VG_HOME_PART" /mnt/home &&
    mkdir /mnt/boot &&
    mount "$EFI_PART" /mnt/boot &&
    swapon "$VG_SWAP_PART";
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't mount partitions"
    return 1
  fi
}

#Check network
while ! connect_wifi; do
  if [ $EXIT_STATUS == 1 ]; then
    exit -1
  fi
  message "$WI_FI_TITLE" "Connection has not been established."
done

#Prepare disk
while ! format_disk; do
  if [ $EXIT_STATUS == 1 ]; then
    exit -1
  fi
  message "$DISK_TITLE" "Disk has not been prepared."
done

