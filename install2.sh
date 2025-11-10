WI_FI_TITLE="Wi-Fi"
DISK_TITLE="Disk"
CORE_TITLE="Core"

MNT="/mnt"

#0 - true; 1 - false
DISK_ENCRYPT=1
DISK_SSD=1
ROOT_PART=""

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

#replaces param = value with new value
replace_conf_param() {
  local param_name="$1"
  local new_value="$2"
  local conf_path="$3"

  sed -i "s|^\($param_name *= *\).*$|\1$new_value|" "$conf_path"
}

#append to param="value" new value
append_conf_param() {
  local param_name="$1"
  local new_value="$2"
  local conf_path="$3"

  #match: PARAM = "value", PARAM= value, PARAM=(value), etc.
  sed -i -E "
    s|^($param_name)[[:space:]]*=[[:space:]]*\"([^\"]*)\"|\1=\"\2 $new_value\"|
    ;s|^($param_name)[[:space:]]*=[[:space:]]*\(([^)]*)\)|\1=(\2 $new_value)|
    ;s|^($param_name)[[:space:]]*=[[:space:]]*([^\"(][^[:space:]]*)|\1=\2 $new_value|
  " "$conf_path"
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
  local NETWORK_DEVICES=$(networkctl list | awk "NR>1 && NF > 0 && $0 !~ /links listed/ {print $2}")
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
    message "$WI_FI_TITLE" "ERROR. Can't switch on device: $WIFI_DEVICE"
    return 1
  fi

  #wifi name
  local NETWORKS=$(iw dev "$WIFI_DEVICE" scan | grep "SSID:" | awk "NF>0 {print $2}")
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
  if is_nvme "$DISK_PATH"; then
    EFI_PART="${DISK_PATH}p1"
    ROOT_PART="${DISK_PATH}p2"
  else
    EFI_PART="${DISK_PATH}1"
    ROOT_PART="${DISK_PATH}2"
  fi
  local ROOT_VOLUME="$ROOT_PART"

  #LUKS
  if [ $DISK_ENCRYPT == 0 ]; then
    local CRYPT_NAME="cryptlvm"
    if ! {
      cryptsetup luksFormat "$ROOT_VOLUME" &&
      cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue --persistent open "$ROOT_VOLUME" "$CRYPT_NAME"
    }; then
      critical_error "$DISK_TITLE" "ERROR. Can't create encrypted volume"
      return 1
    fi
    ROOT_VOLUME="/dev/mapper/$CRYPT_NAME"
  fi

  #LVM
  local VG_NAME="vg0"
  if ! {
    pvcreate "$ROOT_VOLUME" &&
    vgcreate "$VG_NAME" "$ROOT_VOLUME" &&
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

#-------------- Core --------------
install_core() {
  local ADM="amd"
  local INTEL="intel"
  local NVIDIA="nvidia"
  local OTHER="other"
  local GRUB_DEFAULT="$MNT/etc/default/grub"
  local MKINITCPIO_CONF="$MNT/etc/mkinitcpio.conf"

  #processor ucode
  MENU_ITEMS=()
  MENU_ITEMS+=("$AMD" "")
  MENU_ITEMS+=("$INTEL" "")
  MENU_ITEMS+=("$OTHER" "")
  menu "$CORE_TITLE" "Choose your processor manufacturer:"
  local PROCESSOR="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
      return 1
  fi

  #base linux linux-firmware linux-headers - core
  #base-devel go - base development stuff
  #grub efibootmgr - bootloader
  #networkmanager - network
  #pipewire pipewire-alsa pipewire-pulse pipewire-jack - audio
  #wireplumber - the pipewire session manager
  #sudo - for sudo users
  #nano - my favorite editor
  #git - well, git
  if ! pacstrap "$MNT" base linux linux-firmware linux-headers base-devel go grub efibootmgr networkmanager pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sudo nano git; then
    critical_error "$CORE_TITLE" "ERROR. Can't install core packages"
    return 1
  fi

  #"$PROCESSOR"-ucode - microcode for CPU
  if ! [ -z "$PROCESSOR" ] && ! [ "$PROCESSOR" == "$OTHER" ]; then
    if ! pacstrap "$MNT" "$PROCESSOR"-ucode ; then
      critical_error "$CORE_TITLE" "ERROR. Can't install microcode for processor"
      return 1
    fi
  fi

  #lvm2 - for loading logical volumes
  if [ "$DISK_ENCRYPT" == 0 ]; then
    if ! pacstrap "$MNT" lvm2 ; then
      critical_error "$CORE_TITLE" "ERROR. Can't install encryption package"
      return 1
    fi
  fi

  #generating mount points
  if ! genfstab -U "$MNT" >> "$MNT/etc/fstab" ; then
    critical_error "$CORE_TITLE" "ERROR. Can't generate mount points"
    return 1
  fi

  #add multilib
  local PACMAN_CONF="$MNT/etc/pacman.conf"
  echo "[multilib]" >> "$PACMAN_CONF"
  echo "Include = /etc/pacman.d/mirrorlist" >> "$PACMAN_CONF"

  #update mirrors and packages database
  arch-chroot "$MNT" pacman -S reflector
  arch-chroot "$MNT" reflector --protocol https --age 12 --completion-percent 97 --latest 100 --score 7 --sort rate --verbose --connection-timeout 180 --download-timeout 180 --save /etc/pacman.d/mirrorlist
  arch-chroot "$MNT" pacman -Syy

  #time zone
  local ZONE_DIR="/usr/share/zoneinfo"
  local ZONE_INFO=($(find "$MNT""$ZONE_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort))
  read_menu_options "${ZONE_INFO[@]}"
  menu "$CORE_TITLE" "Choose your region:"
  local REGION="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  ZONE_INFO=($(find "$MNT""$ZONE_DIR/$REGION" -mindepth 1 -maxdepth 1 -type f -printf "%f\n" | sort))
  read_menu_options "${ZONE_INFO[@]}"
  menu "$CORE_TITLE" "Choose your city:"
  local CITY="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  if ! {
    arch-chroot "$MNT" ln -sf "$ZONE_DIR/$REGION/$CITY" /etc/localtime
    arch-chroot "$MNT" hwclock --systohc
  }; then
    critical_error "$CORE_TITLE" "ERROR. Can't setup time"
    return 1
  fi

  #language
  local LANGUAGE_FILE="$MNT/etc/locale.gen"
  MENU_ITEMS=()
  while read -r LINE; do
    MENU_ITEMS+=("$LINE" "")
  done < <(grep "^#[^ ]" "$LANGUAGE_FILE" | sed "s/^#//")

  menu "$CORE_TITLE" "Choose your language:"
  local LANGUAGE="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  echo "$LANGUAGE" >> "$LANGUAGE_FILE"
  if ! arch-chroot "$MNT" locale-gen ; then
    critical_error "$CORE_TITLE" "ERROR. Can't setup language"
    return 1
  fi

  #keyboard language
  local LANGUAGE_KEYBOARD=$(echo "$LANGUAGE" | awk "{print $1}")
  echo "LANG=$LANGUAGE_KEYBOARD" > "$MNT/etc/locale.conf"

  #hostname
  inputbox "$CORE" "Enter hostname (computer name):"
  local HOSTNAME="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  echo "$HOSTNAME" > "$MNT/etc/hostname"

  #root password
  echo "Enter root (administrator) password:"
  while ! arch-chroot "$MNT" passwd; do
    echo "!!! Command failed, please try again"
  done

  #new user
  inputbox "$CORE" "Enter username:"
  local USERNAME="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi
  arch-chroot "$MNT" useradd -m -G wheel "$USERNAME"

  echo "Enter user password:"
  while ! arch-chroot "$MNT" passwd "$USERNAME"; do
    echo "!!! Command failed, please try again"
  done

  #enabling sudo
  sed -i 's/^#\s*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$MNT/etc/sudoers"

  #Install yay aur
  local TEMP_DIR="/my_temp"
  local TEMP_DIR_YAY="$TEMP_DIR/yay"
  arch-chroot "$MNT" mkdir "$TEMP_DIR"
  arch-chroot "$MNT" git clone https://aur.archlinux.org/yay.git "$TEMP_DIR_YAY"
  arch-chroot "$MNT" chown -R "$USERNAME" "$TEMP_DIR"
  arch-chroot "$MNT" su - "$USERNAME" -c "makepkg -f -D $TEMP_DIR_YAY"
  PACKAGE=$(ls "$MNT""$TEMP_DIR_YAY" | grep "pkg.tar.zst" | grep -v debug)
  if ! arch-chroot "$MNT" pacman -U --noconfirm "$TEMP_DIR_YAY/$PACKAGE" ; then
    critical_error "$CORE_TITLE" "ERROR. Can't install yay package manager"
    return 1
  fi
  rm -rf "$MNT""$TEMP_DIR"

  #encryption settings
  if [ $DISK_ENCRYPT == 0 ]; then
    #enable kernel module
    HOOKS_LINE=$(grep "^HOOKS=" "$MKINITCPIO_CONF")

    if [[ -z "$HOOKS_LINE" ]]; then
      critical_error "$CORE_TITLE" "ERROR. Cant' install encryption hooks"
      return 1
    fi

    # Strip HOOKS=(...) into array
    HOOKS_ARRAY=($(echo "$HOOKS_LINE" | sed -E "s/^HOOKS=\((.*)\)/\1/"))

    # Rebuild new array, injecting encrypt + lvm2 before filesystems
    NEW_HOOKS=()

    for h in "${HOOKS_ARRAY[@]}"; do
      #skip encrypt lvm2 if exist
      if [[ "$h" == "encrypt" || "$h" == "lvm2" ]]; then
        continue
      fi

      if [[ "$h" == "filesystems" ]]; then
        NEW_HOOKS+=("encrypt")
        NEW_HOOKS+=("lvm2")
      fi

      NEW_HOOKS+=("$h")
    done

    #Write result
    replace_conf_param "HOOKS" "(${NEW_HOOKS[*]})" "$MKINITCPIO_CONF"

    #enable opening encrypted disk on loading
    LVM_DISK_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    append_conf_param "GRUB_CMDLINE_LINUX" "cryptdevice=UUID=$LVM_DISK_UUID:cryptlvm" "$GRUB_DEFAULT"
  fi

  #video drivers
  MENU_ITEMS=()
  MENU_ITEMS+=("$AMD" "")
  MENU_ITEMS+=("$INTEL" "")
  MENU_ITEMS+=("$NVIDIA" "")
  MENU_ITEMS+=("$OTHER" "")
  menu "$CORE_TITLE" "Choose video card vendor:"
  local GPU="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  if ! [ -z "$GPU" ] && ! [ "$GPU" == "$OTHER" ]; then
    local GPU_PACKAGES=""
    #https://wiki.archlinux.org/title/AMDGPU
    if [ "$GPU" == "$AMD" ]; then
      GPU_PACKAGES="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu"

    #https://wiki.archlinux.org/title/Intel_graphics
    elif [ "$GPU" == "$INTEL" ]; then
      GPU_PACKAGES="mesa lib32-mesa vulkan-intel lib32-vulkan-intel"

    #README_NVIDIA
    #https://wiki.archlinux.org/title/NVIDIA
    else
      yesno "$CORE_TITLE" "Is your video card RTX 2060+?"
      local RTX2060="$CHOICE"
      local NVIDIA_DRIVER=""
      if [ $RTX2060 == 0 ]; then
        NVIDIA_DRIVER="nvidia-open-dkms"
      else
        #GeForce 750+
        NVIDIA_DRIVER="nvidia-dkms"
      fi

      GPU_PACKAGES="$NVIDIA_DRIVER nvidia-utils lib32-nvidia-utils"

      #some must have settings
      append_conf_param "GRUB_CMDLINE_LINUX" "nvidia-drm.modeset=1 nvidia-drm.fbdev=1" "$GRUB_DEFAULT"
      append_conf_param "MODULES" "nvidia nvidia_modeset nvidia_uvm nvidia_drm" "$MKINITCPIO_CONF"
      echo "blacklist nouveau" > "$MNT/etc/modprobe.d/blacklist-nouveau.conf"

      #https://wiki.archlinux.org/title/PRIME
      yesno "$CORE_TITLE" "Do you have integrated into CPU video card?"
      if [ "$CHOICE" == 0 ]; then
        local NVIDIA_RULE="$MNT/etc/udev/rules.d/80-nvidia-pm.rules"
        echo '# Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind' >> "$NVIDIA_RULE"
        echo 'ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"' >> "$NVIDIA_RULE"
        echo 'ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"' >> "$NVIDIA_RULE"

        echo '# Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind' >> "$NVIDIA_RULE"
        echo 'ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"' >> "$NVIDIA_RULE"
        echo 'ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"' >> "$NVIDIA_RULE"

        CHOICE="$RTX2060"
        if [ "$CHOICE" == 0 ]; then
          yesno "$CORE_TITLE" "Is your video card RTX 3060+?"
        fi

        NVIDIA_RULE="$MNT/etc/modprobe.d/nvidia-pm.conf"
        if [ "$CHOICE" == 0 ]; then
          echo 'options nvidia "NVreg_DynamicPowerManagement=0x03"' >> "$NVIDIA_RULE"
        else
          echo 'options nvidia "NVreg_DynamicPowerManagement=0x02"' >> "$NVIDIA_RULE"
        fi
      fi

      if ! arch-chroot "$MNT" yay -S nvidia-settings ; then
        critical_error "$CORE_TITLE" "ERROR. Can't install nvidia utils"
        return 1
      fi
    fi

    if ! arch-chroot "$MNT" pacman -S --needed --noconfirm "$GPU_PACKAGES" ; then
      critical_error "$CORE_TITLE" "ERROR. Can't install video drivers"
      return 1
    fi
  fi

  #re-generating initramfs
  if ! arch-chroot "$MNT" mkinitcpio -P ; then
    critical_error "$CORE_TITLE" "ERROR. Can't re-generate initramfs"
    return 1
  fi

  #installing bootloader
  if ! {
    arch-chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="$HOSTNAME" &&
    mkdir "$MNT/boot/EFI/BOOT" &&
    cp "$MNT/boot/EFI/$BOOTLOADER_ID/grubx64.efi" "$MNT/boot/EFI/BOOT/BOOTX64.EFI" &&
    arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
  }; then
    critical_error "$CORE_TITLE" "ERROR. Can't setup bootloader"
    return 1
  fi

  #enable services
  arch-chroot "$MNT" systemctl enable NetworkManager #network

  #ssd optimisation
  if [ "$DISK_SSD" == 0 ]; then
    arch-chroot "$MNT" systemctl enable fstrim.timer
    echo "vm.swappiness=0" > "$MNT/etc/sysctl.d/swappiness.conf"
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

#Install core
while ! install_core; do
  message "$CORE_TITLE" "Linux core has not been installed."
done

