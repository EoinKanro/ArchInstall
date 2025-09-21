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

#check network
while true; do
    if ping -c 3 archlinux.org; then
        echo ">>> Internet is up!"
        break
    else
        echo "!!! No Internet connection"
        connect_wifi
    fi
done

