set -euo pipefail

#WiFi connection
connect_wifi() {
  local ADAPTER_NAME WIFI_DEVICE_NAME NETWORK_NAME NETWORK_PASSWORD

  echo ">>> Conection to WiFi..."
  echo
  while true; do
    iwctl adapter list
    read -rp "Enter adapter name (example: phy0): " ADAPTER_NAME
  
    if iwctl adapter $ADAPTER_NAME set-property Powered on; then
      echo ">>> Adapter $ADAPTER_NAME switched on"
      break
    else
      echo "!!! Wrong name of adapter"
    fi
  done

  while true; do
    iwctl device list
    read -rp "Enter device name (example: wlan0): " WIFI_DEVICE_NAME
  
    if iwctl device $WIFI_DEVICE_NAME set-property Powered on; then
      echo ">>> Device $WIFI_DEVICE_NAME switched on"
      break
    else
      echo "!!! Wrong name of device"
    fi
  done

  while true; do
    iwctl station "$WIFI_DEVICE_NAME" scan
    iwctl station "$WIFI_DEVICE_NAME" get-networks
    read -rp "Enter network name: " NETWORK_NAME
    read -rsp "Enter password: " NETWORK_PASSWORD
	echo
  
    if iwctl --passphrase "$NETWORK_PASSWORD" station "$WIFI_DEVICE_NAME" connect "$NETWORK_NAME"; then
      echo ">>> Connected initiated"
	  
	  echo ">>> Waiting for $WIFI_DEVICE_NAME to get an IP..."
      while ! ip addr show "$WIFI_DEVICE_NAME" | grep -q "inet "; do
        sleep 1
	  done
      echo ">>> Connected to $NETWORK_NAME!"
      break
    else
      echo "!!! Failed to connect to $NETWORK_NAME. Try again."
    fi
  done
}

#Check network
while true; do
  if ping -c 3 archlinux.org; then
    echo ">>> Internet is up!"
    break
  else
    echo "!!! No Internet connection"
    connect_wifi
  fi
done

#Prepare disk
prepare_disk() {
  local DISK_NAME DISK CONFIRM EFI_PART ROOT_PART VG0_PART VG0_ROOT_PART VG0_HOME_PART VG0_SWAP_PART LUKS_PASS1 LUKS_PASS2 TMPFILE
  
  echo ">>> Creating disk partitions..."
  
  echo ">>> Available disks:"
  lsblk -dpno NAME,SIZE,MODEL
  echo
  read -rp "Enter disk name (example: sdb): " DISK_NAME
  DISK="/dev/$DISK_NAME"
  
  # Confirm
  read -rp "!!! All data on $DISK will be erased. Continue? (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" ]]; then 
    echo "Aborted."
	exit 1;
  fi
  
  echo ">>> Erasing disk $DISK..."
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"

  echo ">>> Creating partitions..."
  parted -s "$DISK" mklabel gpt
  # EFI 1GB
  parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 boot on
  # LVM rest
  parted -s "$DISK" mkpart primary 1025MiB 100%

  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"

  #Init LUKS
  echo ">>> Setting up LUKS encryption on root..."
  while true; do
    read -rsp "Enter password for LUKS: " LUKS_PASS1
	echo
    read -rsp "Verify password: " LUKS_PASS2
	echo
	if [[ "$LUKS_PASS1" == "$LUKS_PASS2" ]]; then
	  break
	else
	  echo "Passwords are not equal"
	fi
  done
  
  TMPFILE=$(mktemp)
  chmod 600 "$TMPFILE"
  echo "$LUKS_PASS1" > "$TMPFILE"
  
  cryptsetup luksFormat --batch-mode "$ROOT_PART" --key-file "$TMPFILE"
  cryptsetup open --key-file "$TMPFILE" "$ROOT_PART" cryptlvm
  rm -f "$TMPFILE"

  #Create lvm volumes
  echo ">>> Creating LVM volumes..."
  pvcreate /dev/mapper/cryptlvm
  vgcreate vg0 /dev/mapper/cryptlvm
  lvcreate -L 50G vg0 -n root
  lvcreate -L 8G vg0 -n swap
  lvcreate -l 100%FREE vg0 -n home

  VG0_PART="/dev/vg0"
  VG0_ROOT_PART="$VG0_PART/root"
  VG0_HOME_PART="$VG0_PART/home"
  VG0_SWAP_PART="$VG0_PART/swap"
  echo ">>> Formatting partitions..."
  mkfs.fat -F32 "$EFI_PART"
  mkfs.ext4 "$VG0_ROOT_PART"
  mkfs.ext4 "$VG0_HOME_PART"
  mkswap "$VG0_SWAP_PART"

  #Mount volumes
  echo ">>> Mounting partitions..."
  mount -o noatime "$VG0_ROOT_PART" /mnt
  mkdir /mnt/home
  mount -o noatime "$VG0_HOME_PART" /mnt/home
  mkdir /mnt/boot
  mount "$EFI_PART" /mnt/boot
  swapon "$VG0_SWAP_PART"

  echo ">>> Disk $DISK prepared successfully!"
}

prepare_disk

