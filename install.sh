set -euo pipefail

#WiFi connection
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
  read -rp "Enter password: " NETWORK_PASSWORD
  
  if iwctl --passphrase "$NETWORK_PASSWORD" station "$WIFI_DEVICE_NAME" connect "$NETWORK_NAME"; then
    echo ">>> Connected successfully!"
    break
  else
    echo "!!! Failed to connect to $NETWORK_NAME. Try again."
  fi
done
