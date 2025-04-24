# factory-public

Comando per installare il sistema di failover

```bash
wget -qO- https://raw.githubusercontent.com/dm-italy/factory-public/refs/heads/main/install_failover_script.sh | sudo bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/dm-italy/factory-public/refs/heads/main/install_failover_script.sh -o install_network_failover.sh
```

## Clone user pi

Use this script to clone pi user and disable it

```bash
curl -sSL https://raw.githubusercontent.com/dm-italy/factory-public/refs/heads/main/clone-pi-user-script.sh -o clone-pi-user-script.sh
chmod +x clone-pi-user-script.sh
sudo ./clone-pi-user-script.sh
```
