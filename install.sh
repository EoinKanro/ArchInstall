WI_FI_TITLE="Wi-Fi"
DISK_TITLE="Disk"
CORE_TITLE="Core"
DE_TITLE="Desktop Environment"
APPS_TITLE="Apps"

MNT="/mnt"

#0 - true; 1 - false
DISK_ENCRYPT=1
DISK_SSD=1
ROOT_PART=""
CRYPT_NAME=""
VG_NAME=""
USERNAME=""

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

unmount_all() {
  swapoff -a
  umount -R /mnt
}

#-------------- whiptail functions --------------
CHOICE=""
MENU_ITEMS=()
EXIT_STATUS=0

# "${ARGUMENT[@]}"
read_menu_options() {
  MENU_ITEMS=()
  for ITEM in $@; do
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
    message "$WI_FI_TITLE" "ERROR. Can't switch on device: $WIFI_DEVICE"
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
  #deactivate all swap, LVMs, LUKS if exist or sgdisk will not work
  swapoff -a
  vgchange -an
  cryptsetup close /dev/mapper/*

  #init partition names
  local EFI_PART=""
  if is_nvme "$DISK_PATH"; then
    EFI_PART="${DISK_PATH}p1"
    ROOT_PART="${DISK_PATH}p2"
  else
    EFI_PART="${DISK_PATH}1"
    ROOT_PART="${DISK_PATH}2"
  fi
  local ROOT_VOLUME="$ROOT_PART"

  #remove old vgs on the disk
  for VG in $(pvs --noheadings -o pv_name,vg_name | grep "$ROOT_PART" | awk '{print $2}'); do
    vgremove -ff -y "$VG"
  done
  pvremove -ff -y "$ROOT_PART"

  #erasing
  if ! {
    wipefs -af "$DISK_PATH" &&
    sgdisk --zap-all "$DISK_PATH"
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't erase disk. Try reboot"
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
    critical_error "$DISK_TITLE" "ERROR. Can't create partitions. Try reboot"
    return 1
  fi

  #LUKS optional
  if [ $DISK_ENCRYPT == 0 ]; then
    CRYPT_NAME="cryptlvm$(openssl rand -hex 3)"
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
  VG_NAME="vgarch$(openssl rand -hex 3)"
  if ! {
    pvcreate -ff -y "$ROOT_VOLUME" &&
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
    mount -o "$MOUNT_OPTIONS" "$VG_ROOT_PART" "$MNT" &&
    mkdir "$MNT/home" &&
    mount -o "$MOUNT_OPTIONS" "$VG_HOME_PART" "$MNT/home" &&
    mkdir "$MNT/boot" &&
    mount "$EFI_PART" "$MNT/boot" &&
    swapon "$VG_SWAP_PART";
  }; then
    critical_error "$DISK_TITLE" "ERROR. Can't mount partitions"
    return 1
  fi
}

#-------------- Core --------------
install_core() {
  local AMD="amd"
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
  menu "$CORE_TITLE" "Choose your CPU manufacturer:"
  local PROCESSOR="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
      return 1
  fi

  #base linux linux-firmware linux-headers - core
  #base-devel go - base development stuff
  #lvm2 - for loading logical volumes
  #grub efibootmgr - bootloader
  #networkmanager - network
  #pipewire pipewire-alsa pipewire-pulse pipewire-jack - audio
  #wireplumber - the pipewire session manager
  #sudo - for sudo users
  #nano - my favorite editor
  #git - well, git
  if ! pacstrap "$MNT" base linux linux-firmware linux-headers base-devel lvm2 go grub efibootmgr networkmanager pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sudo nano git; then
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

  #cryptsetup - for disk encryption
  if [ $DISK_ENCRYPT == 0 ]; then
    if ! pacstrap "$MNT" cryptsetup ; then
      critical_error "$CORE_TITLE" "ERROR. Can't install cryptsetup"
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
  arch-chroot "$MNT" pacman -Syy
  arch-chroot "$MNT" pacman -Su --noconfirm reflector
  arch-chroot "$MNT" reflector --protocol https --age 12 --completion-percent 97 --latest 100 --score 7 --sort rate --verbose --connection-timeout 180 --download-timeout 180 --save /etc/pacman.d/mirrorlist

  #time zone
  local ZONE_DIR="/usr/share/zoneinfo"
  MENU_ITEMS=()
  while read -r LINE; do
      MENU_ITEMS+=("$LINE" "")
  done < <(find "$MNT""$ZONE_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)
  menu "$CORE_TITLE" "Choose your region:"
  local REGION="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  MENU_ITEMS=()
  while read -r LINE; do
    MENU_ITEMS+=("$LINE" "")
  done < <(find "$MNT""$ZONE_DIR/$REGION" -mindepth 1 -maxdepth 1 -type f -printf "%f\n" | sort)
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
  local LANGUAGE_KEYBOARD=$(echo "$LANGUAGE" | awk '{print $1}')
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
  USERNAME="$CHOICE"
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
  local PACKAGE=$(ls "$MNT""$TEMP_DIR_YAY" | grep "pkg.tar.zst" | grep -v debug)
  if ! arch-chroot "$MNT" pacman -U --noconfirm "$TEMP_DIR_YAY/$PACKAGE" ; then
    critical_error "$CORE_TITLE" "ERROR. Can't install yay package manager"
    return 1
  fi
  rm -rf "$MNT""$TEMP_DIR"

  #enable LVM and LUKS optional kernel modules
  local HOOKS_LINE=$(grep "^HOOKS=" "$MKINITCPIO_CONF")

  if [[ -z "$HOOKS_LINE" ]]; then
    critical_error "$CORE_TITLE" "ERROR. Cant' enable kernel modules"
    return 1
  fi

  #rebuilding modules
  #https://wiki.archlinux.org/title/Mkinitcpio
  local SYSTEMD="systemd"
  local UDEV="udev"
  MENU_ITEMS=()
  MENU_ITEMS+=("$SYSTEMD" "new, default")
  MENU_ITEMS+=("$UDEV" "old, reliable")
  menu "$CORE_TITLE" "Choose your devices processor:"
  if [ $EXIT_STATUS == 1 ]; then
      return 1
  fi

  local NEW_HOOKS=()
  local USE_UDEV=1
  if [ "$CHOICE" == "$UDEV" ]; then
    USE_UDEV=0
  fi

  #todo usbhid modules
  #complete rebuild bcz there was a bug where default hooks
  #contained modules for udev and systemd at the same time
  NEW_HOOKS+=("base")
  if [ $USE_UDEV == 0 ]; then
    NEW_HOOKS+=("udev")
  else
    NEW_HOOKS+=("$SYSTEMD")
  fi
  NEW_HOOKS+=("autodetect")
  if ! [ "$PROCESSOR" == "$OTHER" ]; then
    NEW_HOOKS+=("microcode")
  fi
  NEW_HOOKS+=("modconf")
  NEW_HOOKS+=("kms")
  NEW_HOOKS+=("keyboard")
  if [ $USE_UDEV == 0 ]; then
    NEW_HOOKS+=("keymap")
    NEW_HOOKS+=("consolefont")
  else
    NEW_HOOKS+=("sd-vconsole")
  fi
  NEW_HOOKS+=("block")
  if [ $DISK_ENCRYPT == 0 ]; then
    if [ $USE_UDEV == 0 ]; then
      NEW_HOOKS+=("encrypt")
    else
      NEW_HOOKS+=("sd-encrypt")
    fi
  fi
  NEW_HOOKS+=("lvm2")
  NEW_HOOKS+=("filesystems")
  NEW_HOOKS+=("fsck")

  #Write result
  replace_conf_param "HOOKS" "(${NEW_HOOKS[*]})" "$MKINITCPIO_CONF"

  #encryption settings
  if [ $DISK_ENCRYPT == 0 ]; then
    #enable opening encrypted disk on loading
    local LVM_DISK_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    if [ $USE_UDEV == 0 ]; then
      append_conf_param "GRUB_CMDLINE_LINUX" "cryptdevice=UUID=$LVM_DISK_UUID:$CRYPT_NAME" "$GRUB_DEFAULT"
    else
      echo "$CRYPT_NAME UUID=$LVM_DISK_UUID none luks" > "$MNT/etc/crypttab.initramfs"
      append_conf_param "GRUB_CMDLINE_LINUX" "rd.luks.name=$LVM_DISK_UUID=$CRYPT_NAME root=/dev/mapper/$VG_NAME-root" "$GRUB_DEFAULT"
    fi
  fi

  #video drivers
  MENU_ITEMS=()
  MENU_ITEMS+=("$AMD" "")
  MENU_ITEMS+=("$INTEL" "")
  MENU_ITEMS+=("$NVIDIA" "")
  MENU_ITEMS+=("$OTHER" "")
  menu "$CORE_TITLE" "Choose GPU manufacturer:"
  local GPU="$CHOICE"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  if ! [ -z "$GPU" ] && ! [ "$GPU" == "$OTHER" ]; then
    local GPU_PACKAGES=()
    #https://wiki.archlinux.org/title/AMDGPU
    if [ "$GPU" == "$AMD" ]; then
      GPU_PACKAGES=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu)

    #https://wiki.archlinux.org/title/Intel_graphics
    elif [ "$GPU" == "$INTEL" ]; then
      GPU_PACKAGES=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel)

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

      GPU_PACKAGES=("$NVIDIA_DRIVER" nvidia-utils lib32-nvidia-utils)

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

      if ! arch-chroot "$MNT" sudo -u "$USERNAME" yay -S --noconfirm nvidia-settings ; then
        critical_error "$CORE_TITLE" "ERROR. Can't install nvidia utils"
        return 1
      fi
    fi

    if ! {
      arch-chroot "$MNT" pacman -Syy &&
      arch-chroot "$MNT" pacman -S --noconfirm ${GPU_PACKAGES[@]}
    }; then
      critical_error "$CORE_TITLE" "ERROR. Can't install video drivers"
      return 1
    fi
  fi

  #re-generating initramfs
  arch-chroot "$MNT" mkinitcpio -P

  #installing bootloader
  if ! {
    arch-chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="$HOSTNAME" &&
    mkdir -p "$MNT/boot/EFI/BOOT" &&
    cp "$MNT/boot/EFI/$HOSTNAME/grubx64.efi" "$MNT/boot/EFI/BOOT/BOOTX64.EFI" &&
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

  #todo firewall, etc
}

#-------------- DE --------------
install_de() {
  local KDE="kde"
  MENU_ITEMS=()
  MENU_ITEMS+=("$KDE" "user friendly")
  MENU_ITEMS+=("hyprland" "fully customizable")
  menu "$DE_TITLE" "Choose environment:"
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi

  if [ "$CHOICE" == "$KDE" ]; then
    # plasma-desktop: the barebones plasma environment.
    # plasma-pa: the KDE audio applet.
    # plasma-nm: the KDE network applet.
    # plasma-systemmonitor: the KDE task manager.
    # plasma-firewall: the KDE firewall.
    # kscreen: the KDE display configurator.
    # kwalletmanager: manage secure vaults ( needed to store the passwords of local applications in an encrypted format ). This also installs kwallet as a dependency, so I don't need to specify it.
    # kwallet-pam: automatically unlocks secure vault upon login ( without this, each time the wallet gets queried it asks for your password to unlock it ).
    # bluedevil: the KDE bluetooth manager.
    # powerdevil: the KDE power manager.
    # power-profiles-daemon: adds 3 power profiles selectable from powerdevil ( power saving, balanced, performance ). Make sure that its service is enabled and running ( it should be ).
    # kdeplasma-addons: some useful addons.
    # xdg-desktop-portal-kde: better integrates the plasma desktop in various windows like file pickers.
    # kde-gtk-config: the native settings integration to manage GTK theming.
    # breeze-gtk: the breeze GTK theme.
    # cups, print-manager: the CUPS print service and the KDE front-end.
    # konsole: the KDE terminal.
    # dolphin dolphin-plugins: the KDE file manager.
    # ffmpegthumbs: video thumbnailer for dolphin.
    # kate: the KDE text editor.
    # okular: the KDE pdf viewer.
    # gwenview: the KDE image viewer.
    # ark: the KDE archive manager.
    # spectacle: the KDE screenshot tool.
    # haruna: mediaplayer
    # discover: app manager
    if ! arch-chroot "$MNT" pacman -Sy --needed --noconfirm plasma-desktop plasma-pa plasma-nm plasma-systemmonitor plasma-firewall kscreen kwalletmanager kwallet-pam bluedevil powerdevil power-profiles-daemon kdeplasma-addons xdg-desktop-portal-kde kde-gtk-config breeze-gtk cups print-manager konsole dolphin dolphin-plugins ffmpegthumbs kate okular gwenview ark spectacle haruna discover ; then
      message "$DE_TITLE" "ERROR. Can't install KDE"
      return 1
    fi
  else
    # hyprland: base hyprland packages
    # kitty: default terminal
    if ! arch-chroot "$MNT" pacman -Sy --needed --noconfirm hyprland kitty ; then
      message "$DE_TITLE" "ERROR. Can't install Hyprland"
      return 1
    fi
  fi

  # ly: minimalistic display manager for choosing desktop environment
  if ! {
    arch-chroot "$MNT" pacman -Sy --needed --noconfirm ly &&
    arch-chroot "$MNT" systemctl enable ly &&
    replace_conf_param animation "colormix" "$MNT/etc/ly/config.ini" &&
    replace_conf_param bigclock "en" "$MNT/etc/ly/config.ini"
  }; then
    message "$DE_TITLE" "ERROR. Can't install display manager"
    return 1
  fi
}

#-------------- Apps --------------
install_apps() {
  local ZEN="zen-browser-bin"
  local TELEGRAM="telegram-desktop-bin"
  local DEBTAP="debtap"
  local YAY_APPS=()
  YAY_APPS+=("$ZEN")
  YAY_APPS+=("$TELEGRAM")
  YAY_APPS+=("$DEBTAP")

  MENU_ITEMS=()
  MENU_ITEMS+=("firefox" "Web browser" OFF)
  MENU_ITEMS+=("$ZEN" "Firefox based web browser but newer" ON)
  MENU_ITEMS+=("$TELEGRAM" "Telegram messenger" OFF)
  MENU_ITEMS+=("steam" "Steam game launcher" OFF)
  MENU_ITEMS+=("$DEBTAP" "Converter of deb packages" ON)
  MENU_ITEMS+=("openrgb" "Rgb controller" OFF)
  MENU_ITEMS+=("easyeffects" "Effects for audio" ON)
  MENU_ITEMS+=("lsp-plugins" "Plugins for easyeffects" ON)
  MENU_ITEMS+=("swh-plugins" "Plugins for easyeffects" ON)
  MENU_ITEMS+=("noto-fonts" "Fonts" ON)
  MENU_ITEMS+=("noto-fonts-cjk" "Fonts" ON)
  MENU_ITEMS+=("noto-fonts-emoji" "Fonts" ON)
  MENU_ITEMS+=("noto-fonts-extra" "Fonts" ON)
  #git clone https://github.com/calf-studio-gear/calf.git

  CHOICE=$(whiptail --title "$APPS_TITLE" --checklist "Choose additional apps (use SPACE):" 20 70 12 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
  EXIT_STATUS=$?
  if [ $EXIT_STATUS == 1 ]; then
    return 1
  fi
  #parse result to array
  local APPS=($(echo "$CHOICE" | tr -d '"'))

  read_menu_options "${APPS[@]}"
  menu "$APPS_TITLE" "Confirm your choice:"
  if [ $EXIT_STATUS == 1 ]; then
    EXIT_STATUS=0
    return 1
  fi

  local PACMAN_APPS_INSTALL=()
  local YAY_APPS_INSTALL=()
  for APP in "${APPS[@]}"; do
    if [[ " ${YAY_APPS[@]} " =~ " ${APP} " ]]; then
      YAY_APPS_INSTALL+=("$APP")
    else
      PACMAN_APPS_INSTALL+=("$APP")
    fi
  done

  if ! {
    arch-chroot "$MNT" pacman -Sy --noconfirm ${PACMAN_APPS_INSTALL[@]} &&
    arch-chroot "$MNT" sudo -u "$USERNAME" yay -S --noconfirm ${YAY_APPS_INSTALL[@]}
  }; then
    message "$APPS_TITLE" "ERROR. Can't install apps"
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
    unmount_all
    exit -1
  fi
  message "$DISK_TITLE" "Disk has not been prepared."
done

#Install core
while ! install_core; do
  if [ $EXIT_STATUS == 1 ]; then
    exit -1
  fi
  message "$CORE_TITLE" "Linux core has not been installed."
done

#Install desktop environment
while ! install_de; do
  if [ $EXIT_STATUS == 1 ]; then
    exit -1
  fi
  message "$DE_TITLE" "Desktop environment has not been installed."
done

#Install additional apps
while ! install_apps; do
  if [ $EXIT_STATUS == 1 ]; then
    exit -1
  fi
  message "$APPS_TITLE" "Additional apps have not been installed."
done

echo "Done. Now you can reboot into your system"
