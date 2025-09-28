set -euo pipefail

yecho() {
  echo -e "\e[33m$1\e[0m"
}

mecho() {
  echo -e "\e[35m$1\e[0m"
}

recho() {
  echo -e "\e[31m$1\e[0m"
}

is_yes() {
  [[ "$1" == "y" || "$1" == "Y" ]]
}

print_help() {
  yecho "ArhInstall usage:"
  echo
  yecho "-help - this help"
  yecho "-default - default installation from erasing disk to desktop environment"
  yecho "-disk - format disk and mount to /mnt"
  yecho "-linux - install default packages and tweak for LVM"
  yecho "-desktop - install desktop environment and programs"
  echo
  yecho "If 'help' or 'default' passed then all other arguments will be ignored"
  yecho "Use the others arguments only when error happened and you need to retry specific step"
}

INPUT_PARAMS=" $* "
contains_input() {
  case "$INPUT_PARAMS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
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

  sed -i "s|^$param_name=\"\(.*\)\"|$param_name=\"\1 $new_value\"|" "$conf_path"
}

connect_wifi() {
  local ADAPTER_NAME WIFI_DEVICE_NAME NETWORK_NAME NETWORK_PASSWORD

  yecho ">>> Connecting to WiFi"
  echo
  while true; do
    iwctl adapter list

    yecho "Enter adapter name (example: phy0):"
    read -r ADAPTER_NAME
  
    if iwctl adapter "$ADAPTER_NAME" set-property Powered on; then
      yecho ">>> Adapter $ADAPTER_NAME switched on"
      break
    else
      recho "!!! Wrong name of adapter"
    fi
  done

  while true; do
    iwctl device list

    yecho "Enter device name (example: wlan0):"
    read -r WIFI_DEVICE_NAME
  
    if iwctl device "$WIFI_DEVICE_NAME" set-property Powered on; then
      yecho ">>> Device $WIFI_DEVICE_NAME switched on"
      break
    else
      recho "!!! Wrong name of device"
    fi
  done

  while true; do
    iwctl station "$WIFI_DEVICE_NAME" scan
    iwctl station "$WIFI_DEVICE_NAME" get-networks

    yecho "Enter network name:"
    read -r NETWORK_NAME
    yecho "Enter password:"
    read -rs NETWORK_PASSWORD
    echo
  
    if iwctl --passphrase "$NETWORK_PASSWORD" station "$WIFI_DEVICE_NAME" connect "$NETWORK_NAME"; then
      yecho ">>> Connection initiated"
    
      yecho ">>> Waiting for $WIFI_DEVICE_NAME to get an IP..."
      while ! ip addr show "$WIFI_DEVICE_NAME" | grep -q "inet "; do
        sleep 1
      done

      yecho ">>> Connected to $NETWORK_NAME!"
      break
    else
      recho "!!! Failed to connect to $NETWORK_NAME. Try again."
    fi
  done
}

#Format one disk using LUKS LVM and mount to /mnt
prepare_disk() {
  local DISK CONFIRM EFI_PART SWAP_SIZE VG0_PART VG0_ROOT_PART VG0_HOME_PART VG0_SWAP_PART

  mecho "### Prepare disk step"
  yecho ">>> Creating disk partitions"

  #Choosing disk
  while true; do
    yecho ">>> Available disks:"
    lsblk -do NAME,SIZE,MODEL
    echo

    yecho "Enter disk name (example: sda): "
    read -r DISK
    DISK="/dev/$DISK"

    if ! (lsblk -dno NAME | grep -q "^$DISK\$"); then
      recho "!!! Wrong name of disk"
      continue
    fi

    recho ">>> All data on $DISK will be erased. Continue? (y/N):"
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      yecho ">>> Aborted"
      continue
    fi

    break
  done
  
  yecho ">>> Erasing disk $DISK"
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"

  yecho ">>> Creating partitions"
  parted -s "$DISK" mklabel gpt
  # EFI 1GB
  parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 boot on
  # LUKS rest
  parted -s "$DISK" mkpart primary 1025MiB 100%

  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"

  #Init LUKS
  yecho ">>> Setting up LUKS encryption on root"
  cryptsetup luksFormat "$ROOT_PART"
  cryptsetup open "$ROOT_PART" cryptlvm

  while true; do
    yecho ">>> Selecting swap size"

    echo
    recho "Recommendations:"
    yecho "With hibernation (not suspension):"
    yecho "# 1.1 * RAM size"
    yecho "Without hibernation:"
    yecho "# 2 * RAM size - with < 4 GB RAM"
    yecho "# RAM size - with 4 - 8 GB RAM"
    yecho "# 4 - 8 GB - with 8 - 16 GB RAM"
    yecho "# 2 - 4 GB - with 16 - 32 GB RAM"
    yecho "# 2 GB - with 32+ GB RAM"
    echo

    yecho "Enter swap size in GB:"
    read -r SWAP_SIZE
    if ! [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]]; then
      recho "!!! Wrong value"
      continue
    fi
    break
  done

  #Create lvm volumes
  yecho ">>> Creating LVM volumes"
  pvcreate /dev/mapper/cryptlvm
  vgcreate vg0 /dev/mapper/cryptlvm
  lvcreate -L 50G vg0 -n root
  lvcreate -L "$SWAP_SIZE"G vg0 -n swap
  lvcreate -l 100%FREE vg0 -n home

  yecho ">>> Formatting partitions"
  VG0_PART="/dev/vg0"
  VG0_ROOT_PART="$VG0_PART/root"
  VG0_HOME_PART="$VG0_PART/home"
  VG0_SWAP_PART="$VG0_PART/swap"
  mkfs.fat -F32 "$EFI_PART"
  mkfs.ext4 "$VG0_ROOT_PART"
  mkfs.ext4 "$VG0_HOME_PART"
  mkswap "$VG0_SWAP_PART"

  #Mount volumes
  yecho ">>> Mounting partitions"
  mount -o noatime "$VG0_ROOT_PART" /mnt
  mkdir /mnt/home
  mount -o noatime "$VG0_HOME_PART" /mnt/home
  mkdir /mnt/boot
  mount "$EFI_PART" /mnt/boot
  swapon "$VG0_SWAP_PART"

  mecho "### Prepare disk step finished"
}

# Install default packages and drivers
# Set language, timezone and hostname
# Create user
# Set LVM settings
install_linux() {
  local PROCESSOR REGION CITY LANGUAGE HOSTNAME MKINITCPIO_CONF HOOKS_LINE HOOKS_ARRAY NEW_HOOKS BOOTLOADER_ID LVM_DISK_UUID USER_NAME CHOICE

  mecho "### Install linux step"

  #Intel / AMD ucode
  while true; do
    yecho "What processor do you have? (intel/amd):"
    read -r PROCESSOR
  
    if [[ "$PROCESSOR" == "amd" || "$PROCESSOR" == "intel" ]]; then
      break;
    else
      recho "!!! Wrong name of processor"
    fi
  done
  
  #base linux linux-firmware - core
  #base-devel - base development stuff
  #lvm2 - for loading encrypted disk
  #nano - my favorite editor
  #sudo - for sudo users
  #git - well, git
  #"$PROCESSOR"-ucode - microcode for CPU
  #grub efibootmgr - bootloader
  #pipewire pipewire-alsa pipewire-pulse pipewire-jack - for the new audio framework replacing pulse and jack
  #wireplumber - the pipewire session manager
  #networkmanager - network
  yecho ">>> Installing basic packages"
  pacstrap /mnt base base-devel linux linux-firmware lvm2 nano sudo git "$PROCESSOR"-ucode grub efibootmgr pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber networkmanager

  #Generate instructions for mounting disks as they are now
  yecho ">>> Generating mount config"
  genfstab -U /mnt >> /mnt/etc/fstab
  
  #Choose fastest mirrors
  yecho ">>> Updating mirrors list"
  arch-chroot /mnt pacman -S reflector
  arch-chroot /mnt reflector --protocol https --age 12 --completion-percent 97 --latest 100 --score 7 --sort rate --verbose --connection-timeout 180 --download-timeout 180 --save /etc/pacman.d/mirrorlist
  arch-chroot /mnt pacman -Syy
  
  #Setup root password
  yecho ">>> Setting up root password"
  while ! arch-chroot /mnt passwd; do
    recho "!!! Command failed, please try again"
  done
  
  #Setup timezone
  yecho ">>> Setting up timezone"
  
  while true; do
    yecho ">>> Available regions:"
    arch-chroot /mnt find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort | tr '\n' ' '
    yecho "Choose region:"
    read -r REGION
  
    if arch-chroot /mnt test -d "/usr/share/zoneinfo/$REGION"; then
      yecho ">>> Selected region: $REGION"
      break
    else
      recho "!!! Region '$REGION' does not exist. Try again."
    fi
  done
  
  while true; do
    yecho ">>> Available cities:"
    arch-chroot /mnt find /usr/share/zoneinfo/"$REGION" -mindepth 1 -maxdepth 1 -printf "%f\n" | sort | tr '\n' ' '
    yecho "Choose city:"
    read -r CITY
  
    if arch-chroot /mnt test -f "/usr/share/zoneinfo/$REGION/$CITY"; then
      yecho ">>> Selected city: $CITY"
      break
    else
      recho "!!! City '$CITY' does not exist. Try again."
    fi
  done
  
  arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$REGION"/"$CITY" /etc/localtime
  arch-chroot /mnt hwclock --systohc
  
  #Setup language
  yecho ">>> Setting up language"
  arch-chroot /mnt nano /etc/locale.gen
  arch-chroot /mnt locale-gen
  
  yecho "Enter main language (example: en_US.UTF-8): "
  read -r LANGUAGE
  echo "LANG=$LANGUAGE" > /mnt/etc/locale.conf
  
  #Setup hostname
  yecho ">>> Setting up hostname"
  yecho "Enter hostname (computer name):"
  read -r HOSTNAME
  echo "$HOSTNAME" > /mnt/etc/hostname
  
  #Enabling encryption in hooks
  yecho ">>> Setting up encryption hooks"
  MKINITCPIO_CONF="/mnt/etc/mkinitcpio.conf"
  HOOKS_LINE=$(grep "^HOOKS=" "$MKINITCPIO_CONF")
  
  if [[ -z "$HOOKS_LINE" ]]; then
    recho "!!! No HOOKS= line found in $MKINITCPIO_CONF"
    exit 1
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
  replace_conf_param HOOKS "(${NEW_HOOKS[*]})" "$MKINITCPIO_CONF"
  
  yecho ">>> Updated HOOKS: (${NEW_HOOKS[*]})"
  yecho ">>> Regenerating initramfs"
  arch-chroot /mnt mkinitcpio -P
  
  #Setup bootloader
  yecho ">>> Setting up bootloader"
  yecho "Enter bootloader id (you will see it in F12):"
  read -r BOOTLOADER_ID
  arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="$BOOTLOADER_ID"
  mkdir /mnt/boot/EFI/BOOT
  cp /mnt/boot/EFI/"$BOOTLOADER_ID"/grubx64.efi /mnt/boot/EFI/BOOT/BOOTX64.EFI
  
  #Open lvm on load
  if [ -z "$ROOT_PART" ]; then
    while ! [ -b "$ROOT_PART" ]; do
        yecho ">>> All partitions:"
        lsblk -po NAME
        yecho "Write full path to LUKS partition (example: /dev/sda2):"
        read -r ROOT_PART
    done
  fi
  LVM_DISK_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  append_conf_param GRUB_CMDLINE_LINUX "cryptdevice=UUID=$LVM_DISK_UUID:cryptlvm" "/mnt/etc/default/grub"
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  
  #Add user
  yecho ">>> Adding new user"
  yecho "Enter user name:"
  read -r USER_NAME
  arch-chroot /mnt useradd -m -G wheel "$USER_NAME"
  while ! arch-chroot /mnt passwd "$USER_NAME"; do
    recho "!!! Command failed, please try again"
  done
  #Uncomment line
  sed -i 's/^#\s*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
  
  #Install bluetooth
  yecho ">>> Installing bluetooth"
  yecho "Do you need bluetooth support? (y/N):"
  read -r CHOICE
  if is_yes "$CHOICE"; then
    arch-chroot /mnt pacman -S --needed bluez bluez-utils
    arch-chroot /mnt systemctl enable bluetooth
  fi
  
  #Install disks extra
  yecho ">>> Installing disks extra"
  arch-chroot /mnt pacman -S --needed nfs-utils ntfs-3g exfatprogs
    
  #Install video drivers
  yecho ">>> Installing video drivers"
  echo "[multilib]" >> /mnt/etc/pacman.conf
  echo "Include = /etc/pacman.d/mirrorlist" >> /mnt/etc/pacman.conf
  arch-chroot /mnt pacman -Syu

  #https://wiki.archlinux.org/title/Intel_graphics
  CHOICE=""
  yecho "Do you need Intel video driver? {y/N):"
  read -r CHOICE
  if is_yes "$CHOICE"; then
    arch-chroot /mnt pacman -S --needed mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  fi

  #https://wiki.archlinux.org/title/AMDGPU
  CHOICE=""
  yecho "Do you need AMD video driver? {y/N):"
  read -r CHOICE
  if is_yes "$CHOICE"; then
    arch-chroot /mnt pacman -S --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu
  fi

  #https://wiki.archlinux.org/title/Nouveau
  CHOICE=""
  yecho "Do you need Nvidia video driver? {y/N):"
  read -r CHOICE
  if is_yes "$CHOICE"; then
    arch-chroot /mnt pacman -S --needed mesa lib32-mesa vulkan-nouveau lib32-vulkan-nouveau xf86-video-nouveau

    #https://wiki.archlinux.org/title/PRIME
    CHOICE=""
    yecho "Do you PRIME for hybrid system? {y/N):"
    read -r CHOICE
    if is_yes "$CHOICE"; then
      echo '# Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind' >> /mnt/etc/udev/rules.d/80-nvidia-pm.rules
      echo 'ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"' >> /mnt/etc/udev/rules.d/80-nvidia-pm.rules
      echo 'ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"' >> /mnt/etc/udev/rules.d/80-nvidia-pm.rules

      echo '# Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind' >> /mnt/etc/udev/rules.d/80-nvidia-pm.rules
      echo 'ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"' >> /mnt/etc/udev/rules.d/80-nvidia-pm.rules
      echo 'ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"' >> /mnt/etc/udev/rules.d/80-nvidia-pm.rules

      CHOICE=""
      yecho "Is the videocard Ampere+? {y/N):"
      read -r CHOICE
      if is_yes "$CHOICE"; then
        echo 'options nvidia "NVreg_DynamicPowerManagement=0x03"' >> /mnt/etc/modprobe.d/nvidia-pm.conf
      else
        echo 'options nvidia "NVreg_DynamicPowerManagement=0x02"' >> /mnt/etc/modprobe.d/nvidia-pm.conf
      fi
    fi
  fi
  
  #Enable services
  yecho ">>> Enabling services"
  arch-chroot /mnt systemctl enable NetworkManager #network
  arch-chroot /mnt systemctl enable fstrim.timer #ssd optimisation
  arch-chroot /mnt sysctl vm.swappiness=0 #ssd optimisation
  
  mecho "### Install linux step finished"
}

install_kde() {
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
  arch-chroot /mnt pacman -S --needed plasma-desktop plasma-pa plasma-nm plasma-systemmonitor plasma-firewall kscreen kwalletmanager kwallet-pam bluedevil powerdevil power-profiles-daemon kdeplasma-addons xdg-desktop-portal-kde kde-gtk-config breeze-gtk cups print-manager konsole dolphin dolphin-plugins ffmpegthumbs kate okular gwenview ark spectacle haruna discover
}

install_hyprland() {
  yecho ">>> Installing base hyprland package"
  # hyprland: base hyprland packages
  arch-chroot /mnt pacman -S --needed hyprland

  # hypridle: Hyprland’s idle management daemon
  # hyprlock: screen lock for Hyprland
  # hyprcursor: a new cursor theme format
  # xdg-desktop-portal-hyprland: handles a lot of stuff for your desktop, like file pickers, screensharing, etc
  # hyprpolkitagent: pop up a window asking you for a password whenever an app wants to elevate its privileges
  # qt6-wayland: qt support, some graphical stuff
  # hyprland-qt-support: provides a QML style for hypr* qt6 apps
  # noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra - font's to not see squares
  # rofi: A window switcher, application launcher and dmenu replacement
  # hyprpicker: color picker
  # nemo: Cinnamon file manager
  # nemo-fileroller: extension for archives
  # nm-applet: gui for network manager
  yecho ">>> Additional packages installation"
  recho "Don't install it if you are going to use dotfiles like end_4's Hyprland dotfiles"
  recho "https://github.com/end-4/dots-hyprland"
  arch-chroot /mnt pacman -S --needed hypridle hyprlock hyprcursor xdg-desktop-portal-hyprland hyprpolkitagent qt6-wayland hyprland-qt-support noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra rofi hyprpicker nemo nemo-fileroller nm-applet

  #todo https://wiki.hypr.land/Useful-Utilities/Clipboard-Managers/ clipse?
  #todo https://wiki.hypr.land/Hypr-Ecosystem/hypridle/
  #todo https://wiki.hypr.land/Hypr-Ecosystem/hyprcursor/

  yecho "For customization you can read wiki: https://wiki.hypr.land/Configuring/"
}

install_desktop() {
  local DE
  mecho "### Install desktop step"

  while true; do
    yecho "What desktop environment to install? (1-kde plasma / 2-hyprland: NOT RECOMMENDED WITH NVIDIA):"
    read -r DE
    if [[ "$DE" != "1" && "$DE" != "2" ]]; then
      recho "!!! Wrong answer"
      continue
    fi

    if [[ "$DE" == "1" ]]; then
      install_kde
    else
      install_hyprland
    fi
    break
  done

  #environment manager
  yecho ">>> Installing environment manager"
  arch-chroot /mnt pacman -S --needed ly
  arch-chroot /mnt systemctl enable ly
  replace_conf_param animation colormix /mnt/etc/ly/config.ini
  replace_conf_param bigclock en /mnt/etc/ly/config.ini

  #flatpak
  yecho ">>> Installing flatpak"
  arch-chroot /mnt pacman -S --needed flatpak
  arch-chroot /mnt flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

  #zen browser
  yecho ">>> Installing zen browser"
  arch-chroot /mnt flatpak install flathub app.zen_browser.zen

  #kando
  yecho ">>> Installing kando"
  arch-chroot /mnt flatpak install flathub menu.kando.Kando

  mecho "### Install desktop step finished"
}

if [ $# -eq 0 ] || contains_input "-help"; then
  print_help
  exit 0
fi

#Check network
while true; do
  if ping -c 3 archlinux.org; then
    yecho ">>> Internet is up!"
    break
  else
    recho "!!! No Internet connection"
    connect_wifi
  fi
done

if contains_input "-default"; then
  prepare_disk
  install_linux
  install_desktop
else
  if contains_input "-disk"; then
    prepare_disk
  fi
  if contains_input "-linux"; then
    install_linux
  fi
  if contains_input "-desktop"; then
    install_desktop
  fi
fi

yecho "Reboot? (y/N)"
read -r CONFIRM
if is_yes "$CONFIRM"; then
  swapoff --all
  umount -R /mnt
  vgchange -an vg0
  cryptsetup close cryptlvm
  reboot
fi
