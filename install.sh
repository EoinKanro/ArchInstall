set -euo pipefail

yecho() {
  echo -e "\e[33m$1\e[0m"
}

recho() {
  echo -e "\e[31m$1\e[0m"
}

#WiFi connection
connect_wifi() {
  local ADAPTER_NAME WIFI_DEVICE_NAME NETWORK_NAME NETWORK_PASSWORD

  yecho ">>> Conecting to WiFi"
  echo
  while true; do
    iwctl adapter list
    read -rp "Enter adapter name (example: phy0): " ADAPTER_NAME
  
    if iwctl adapter $ADAPTER_NAME set-property Powered on; then
      yecho ">>> Adapter $ADAPTER_NAME switched on"
      break
    else
      recho "!!! Wrong name of adapter"
    fi
  done

  while true; do
    iwctl device list
    read -rp "Enter device name (example: wlan0): " WIFI_DEVICE_NAME
  
    if iwctl device $WIFI_DEVICE_NAME set-property Powered on; then
      yecho ">>> Device $WIFI_DEVICE_NAME switched on"
      break
    else
      recho "!!! Wrong name of device"
    fi
  done

  while true; do
    iwctl station "$WIFI_DEVICE_NAME" scan
    iwctl station "$WIFI_DEVICE_NAME" get-networks
    read -rp "Enter network name: " NETWORK_NAME
    read -rsp "Enter password: " NETWORK_PASSWORD
	echo
  
    if iwctl --passphrase "$NETWORK_PASSWORD" station "$WIFI_DEVICE_NAME" connect "$NETWORK_NAME"; then
      yecho ">>> Connected initiated"
	  
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

#Prepare disk
prepare_disk() {
  local DISK_NAME DISK CONFIRM EFI_PART VG0_PART VG0_ROOT_PART VG0_HOME_PART VG0_SWAP_PART LUKS_PASS1 LUKS_PASS2 TMPFILE
  
  yecho ">>> Creating disk partitions"
  
  yecho ">>> Available disks:"
  lsblk -dpno NAME,SIZE,MODEL
  echo
  read -rp "Enter disk name (example: sdb): " DISK_NAME
  DISK="/dev/$DISK_NAME"
  
  # Confirm
  read -rp "!!! All data on $DISK will be erased. Continue? (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" ]]; then 
    yecho "Aborted."
	exit 1;
  fi
  
  yecho ">>> Erasing disk $DISK"
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"

  yecho ">>> Creating partitions"
  parted -s "$DISK" mklabel gpt
  # EFI 1GB
  parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 boot on
  # LVM rest
  parted -s "$DISK" mkpart primary 1025MiB 100%

  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"

  #Init LUKS
  yecho ">>> Setting up LUKS encryption on root"
  cryptsetup luksFormat "$ROOT_PART"
  cryptsetup open "$ROOT_PART" cryptlvm

  #Create lvm volumes
  yecho ">>> Creating LVM volumes"
  pvcreate /dev/mapper/cryptlvm
  vgcreate vg0 /dev/mapper/cryptlvm
  lvcreate -L 50G vg0 -n root
  lvcreate -L 8G vg0 -n swap
  lvcreate -l 100%FREE vg0 -n home

  VG0_PART="/dev/vg0"
  VG0_ROOT_PART="$VG0_PART/root"
  VG0_HOME_PART="$VG0_PART/home"
  VG0_SWAP_PART="$VG0_PART/swap"
  yecho ">>> Formatting partitions"
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

  yecho ">>> Disk $DISK prepared successfully!"
}

prepare_disk

#Install linux
install_linux() {
  local PROCESSOR REGION CITY LANGUAGE HOSTNAME MKINITCPIO_CONF HOOKS_LINE HOOKS_ARRAY NEW_HOOKS BOOTLOADER_ID LVM_DISK_UUID GRUB_FILE USER_NAME NEED_BLUETOOTH NEED_INTEL_VIDEO NEED_AMD_VIDEO NEED_NVIDIA_VIDEO
  
  yecho ">>> Installing Linux"
  
  #Intel / AMD ucode
  while true; do
    read -rp "What processor do you have? (intel/amd) :" PROCESSOR
	
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
  pacstrap /mnt base base-devel linux linux-firmware lvm2 nano sudo git "$PROCESSOR"-ucode grub efibootmgr pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber networkmanager

  #Generate instructions for mounting disks as they are now
  genfstab -U /mnt >> /mnt/etc/fstab
  
  #Choose fastest mirrors
  yecho ">>> Updating mirros list"
  arch-chroot /mnt pacman -S reflector
  arch-chroot /mnt reflector --protocol https --age 12 --completion-percent 97 --latest 100 --score 7 --sort rate --verbose --connection-timeout 180 --download-timeout 180 --save /etc/pacman.d/mirrorlist
  arch-chroot /mnt pacman -Syy
  
  #Setup root password
  yecho ">>> Setting up root password"
  arch-chroot /mnt passwd
  
  #Setup timezone
  yecho ">>> Setting up timezone"
  
  while true; do
    yecho ">>> Available regions:"
    arch-chroot /mnt find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort | tr '\n' ' '
	read -rp "Choose region: " REGION
	
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
	read -rp "Choose city: " CITY
	
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
  
  read -rp "Enter main language (example: en_US.UTF-8): " LANGUAGE
  echo "LANG=$LANGUAGE" > /mnt/etc/locale.conf
  
  #Setup hostname
  yecho ">>> Setting up hostname"
  read -rp "Enter hostname: " HOSTNAME
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
  sed -i "s|^HOOKS=.*|HOOKS=(${NEW_HOOKS[*]})|" "$MKINITCPIO_CONF"
  
  yecho ">>> Updated HOOKS: (${NEW_HOOKS[*]})"
  yecho ">>> Regenerating initramfs"
  arch-chroot /mnt mkinitcpio -P
  
  #Setup bootloader
  yecho ">>> Setting up bootloader"
  read -rp "Enter bootloader id: " BOOTLOADER_ID
  arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="$BOOTLOADER_ID"
  mkdir /mnt/boot/EFI/BOOT
  cp /mnt/boot/EFI/"$BOOTLOADER_ID"/grubx64.efi /mnt/boot/EFI/BOOT/BOOTX64.EFI
  
  #Open lvm on load
  LVM_DISK_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  GRUB_FILE="/mnt/etc/default/grub"
  if ! grep -q "cryptdevice=UUID=$LVM_DISK_UUID:cryptlvm" "$GRUB_FILE"; then
    sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 cryptdevice=UUID=$LVM_DISK_UUID:cryptlvm\"|" "$GRUB_FILE"
  fi
  
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  
  #Add user
  yecho ">>> Adding new user"
  read -rp "Enter user name: " USER_NAME
  arch-chroot /mnt useradd -m -G wheel "$USER_NAME"
  arch-chroot /mnt passwd "$USER_NAME"
  #Uncomment line
  sed -i 's/^#\s*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
  
  #Install bluetooth
  yecho ">>> Installing bluetooth"
  read -rp "Do you need bluetooth support? (y/n): " NEED_BLUETOOTH
  if [[ "$NEED_BLUETOOTH" == "y" ]]; then
    arch-chroot /mnt pacman -S --needed bluez bluez-utils
  fi
  
  #Install disks extra
  yecho ">>> Installing disks extra"
  arch-chroot /mnt pacman -S --needed nfs-utils ntfs-3g exfatprogs
  
  #Install video drivers
  yecho ">>> Installing video drivers"
  echo "[multilib]" >> /mnt/etc/pacman.conf
  echo "Include = /etc/pacman.d/mirrorlist" >> /mnt/etc/pacman.conf
  arch-chroot /mnt pacman -Syu
  
  read -rp "Do you need Intel video driver? {y/n): " NEED_INTEL_VIDEO
  if [[ "$NEED_INTEL_VIDEO" == "y" ]]; then
    arch-chroot /mnt pacman -S --needed mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  fi
  
  read -rp "Do you need AMD video driver? {y/n): " NEED_AMD_VIDEO
  if [[ "$NEED_AMD_VIDEO" == "y" ]]; then
    arch-chroot /mnt pacman -S --needed linux-firmware-amdgpu mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver
  fi
  
  read -rp "Do you need Nvidia video driver? {y/n): " NEED_NVIDIA_VIDEO
  if [[ "$NEED_NVIDIA_VIDEO" == "y" ]]; then
    arch-chroot /mnt pacman -S --needed mesa lib32-mesa vulkan-nouveau lib32-vulkan-nouveau
  fi
  
  #Enable services
  yecho ">>> Enabling services"
  arch-chroot /mnt systemctl enable NetworkManager #network
  arch-chroot /mnt systemctl enable fstrim.timer #ssd optimisation
  arch-chroot /mnt sysctl vm.swappiness=0 #ssd optimisation
  
  if [[ "$NEED_BLUETOOTH" == "y" ]]; then
    arch-chroot /mnt systemctl enable bluetooth
  fi
  
  yecho ">>> Finished basic linux installation"
}

install_linux

install_desktop() {
yecho ">>> Installing desktop environment"
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
# dolphin: the KDE file manager.
# ffmpegthumbs: video thumbnailer for dolphin.
# kate: the KDE text editor.
# okular: the KDE pdf viewer.
# gwenview: the KDE image viewer.
# ark: the KDE archive manager.
# spectacle: the KDE screenshot tool.
# haruna: mediaplayer
arch-chroot /mnt pacman -S --needed plasma-desktop plasma-pa plasma-nm plasma-systemmonitor plasma-firewall kscreen kwalletmanager kwallet-pam bluedevil powerdevil power-profiles-daemon kdeplasma-addons xdg-desktop-portal-kde kde-gtk-config breeze-gtk cups print-manager konsole dolphin ffmpegthumbs kate okular gwenview ark spectacle haruna

#environment manager
yecho ">>> Installing environment manager"
arch-chroot /mnt pacman -S --needed sddm
arch-chroot /mnt systemctl enable sddm
arch-chroot /mnt pacman -S --needed sddm-kcm

#flatpak
yecho ">>> Installing flatpak"
arch-chroot /mnt pacman -S --needed flatpak
arch-chroot /mnt flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

#zen browser
yecho ">>> Installing zen browser"
arch-chroot /mnt flatpak install flathub app.zen_browser.zen

}

install_desktop

read -rp "Reboot? (y/n) " CONFIRM
if [[ "$CONFIRM" == "y" ]]; then
  swapoff --all
  umount -R /mnt
  vgchange -an vg0
  cryptsetup close cryptlvm
  reboot
fi
