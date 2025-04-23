#!/bin/bash

# Script di installazione per configurazione failover con keepalived
# tra interfaccia primaria (eth1) e secondaria (wwan0)

# Colori per output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funzione per stampare messaggi con formato
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Verifica se lo script è eseguito come root
if [ "$EUID" -ne 0 ]; then
  print_error "Questo script deve essere eseguito come root."
  exit 1
fi

# Input dei parametri
read -p "Inserisci il nome dell'interfaccia di rete primaria [eth1]: " PRIMARY_INTERFACE
PRIMARY_INTERFACE=${PRIMARY_INTERFACE:-eth1}

read -p "Inserisci il nome dell'interfaccia di rete secondaria [wwan0]: " SECONDARY_INTERFACE
SECONDARY_INTERFACE=${SECONDARY_INTERFACE:-wwan0}

read -p "Inserisci l'indirizzo IP da monitorare con ping [8.8.8.8]: " PING_IP
PING_IP=${PING_IP:-8.8.8.8}

# Rileva automaticamente i gateway delle interfacce
print_info "Rilevamento dei gateway..."

# Rileva il gateway dell'interfaccia primaria
PRIMARY_GATEWAY=$(ip route | grep "default via" | grep "$PRIMARY_INTERFACE" | awk '{print $3}')
if [ -z "$PRIMARY_GATEWAY" ]; then
    # Se non è presente un gateway default, cerca altre rotte attraverso l'interfaccia
    PRIMARY_GATEWAY=$(ip route | grep "$PRIMARY_INTERFACE" | head -n 1 | awk '{print $1}')
    if [ -z "$PRIMARY_GATEWAY" ]; then
        print_warning "Non è stato possibile rilevare automaticamente il gateway per $PRIMARY_INTERFACE"
        PRIMARY_GATEWAY="10.0.3.1"  # Default in caso di mancato rilevamento
    fi
fi

print_info "Gateway rilevato per $PRIMARY_INTERFACE: $PRIMARY_GATEWAY"
read -p "Vuoi modificare il gateway dell'interfaccia primaria? [$PRIMARY_GATEWAY]: " NEW_PRIMARY_GATEWAY
PRIMARY_GATEWAY=${NEW_PRIMARY_GATEWAY:-$PRIMARY_GATEWAY}

# Rileva il gateway dell'interfaccia secondaria
SECONDARY_GATEWAY=$(ip route | grep "default via" | grep "$SECONDARY_INTERFACE" | awk '{print $3}')
if [ -z "$SECONDARY_GATEWAY" ]; then
    # Se non è presente un gateway default, cerca altre rotte attraverso l'interfaccia
    SECONDARY_GATEWAY=$(ip route | grep "$SECONDARY_INTERFACE" | head -n 1 | awk '{print $1}')
    if [ -z "$SECONDARY_GATEWAY" ]; then
        print_warning "Non è stato possibile rilevare automaticamente il gateway per $SECONDARY_INTERFACE"
        SECONDARY_GATEWAY="10.217.145.117"  # Default in caso di mancato rilevamento
    fi
fi

print_info "Gateway rilevato per $SECONDARY_INTERFACE: $SECONDARY_GATEWAY"
read -p "Vuoi modificare il gateway dell'interfaccia secondaria? [$SECONDARY_GATEWAY]: " NEW_SECONDARY_GATEWAY
SECONDARY_GATEWAY=${NEW_SECONDARY_GATEWAY:-$SECONDARY_GATEWAY}

read -p "Inserisci l'APN per la connessione 1nce [iot.1nce.net]: " APN
APN=${APN:-iot.1nce.net}

# Directory di lavoro
SCRIPT_DIR="/usr/local/bin"
mkdir -p $SCRIPT_DIR

print_info "Installazione di keepalived..."
apt-get update
apt-get install -y keepalived

# Creazione script di ping per verificare la connettività di eth1
print_info "Creazione dello script di ping check-eth1.sh..."
cat > $SCRIPT_DIR/check-eth1.sh << EOF
#!/bin/bash
PING_TARGET="$PING_IP"
ETH_CARD="$PRIMARY_INTERFACE"
ping -I \$ETH_CARD -c 1 -W 2 \$PING_TARGET > /dev/null

if [ \$? -eq 0 ]; then
    # logger -t keepalived " ping \$PING_TARGET -> OK"
    exit 0
else
    logger -t keepalived "ERROR ping \$PING_TARGET via \$ETH_CARD -> KO"
    exit 1
fi
EOF

chmod +x $SCRIPT_DIR/check-eth1.sh

# Creazione script di failover handler
print_info "Creazione dello script di failover keepalived-failover-handler.sh..."
cat > $SCRIPT_DIR/keepalived-failover-handler.sh << EOF
#!/bin/bash
INSTANCE="\$1"
STATE="\$3"
PRIORITY="\$2"
logger -t keepalived "instance '\$INSTANCE' state '\$STATE' priority '\$PRIORITY'"

case "\$STATE" in
    "MASTER")
        logger -t keepalived "[\$INSTANCE] Ripristino su $PRIMARY_INTERFACE \$PRIORITY"
        # Rimuovi tutte le rotte predefinite esistenti
        ip route flush cache
        ip route show | grep ^default | while read route; do
            ip route del \$route
        done
        # Configura $PRIMARY_INTERFACE come gateway principale
        ip route add default via $PRIMARY_GATEWAY dev $PRIMARY_INTERFACE metric 100
        ;;
    "FAULT")
        logger -t keepalived "[\$INSTANCE] attivo backup su $SECONDARY_INTERFACE \$PRIORITY"
        # Rimuovi tutte le rotte predefinite esistenti
        ip route flush cache
        ip route show | grep ^default | while read route; do
            ip route del \$route
        done
        # Configura $SECONDARY_INTERFACE come gateway principale e $PRIMARY_INTERFACE come backup
        ip route add default via $SECONDARY_GATEWAY dev $SECONDARY_INTERFACE metric 100
        ip route add default via $PRIMARY_GATEWAY dev $PRIMARY_INTERFACE metric 300
        ;;
    "BACKUP")
        logger -t keepalived "[\$INSTANCE] Stato BACKUP ignorato intenzionalmente \$PRIORITY"
        # Non fare nulla in stato BACKUP
        ;;
    *)
        logger -t keepalived "Evento keepalived sconosciuto: \$STATE con priorità \$PRIORITY"
        ;;
esac

# Mostra la tabella di routing attuale per debug (solo per MASTER e FAULT)
if [ "\$STATE" = "MASTER" ] || [ "\$STATE" = "FAULT" ]; then
    logger -t keepalived "Nuova tabella di routing dopo transizione a \$STATE:"
    ip route show | grep ^default | logger -t keepalived
fi
EOF

chmod +x $SCRIPT_DIR/keepalived-failover-handler.sh

# Creazione della configurazione di keepalived
print_info "Creazione della configurazione di keepalived..."
cat > /etc/keepalived/keepalived.conf << EOF
global_defs {
    enable_script_security
    script_user root
}


vrrp_script chk_eth1 {
    script "$SCRIPT_DIR/check-eth1.sh"
    interval 5
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface $PRIMARY_INTERFACE
    virtual_router_id 51
    priority 100
    advert_int 1

    nopreempt               # Impedisce di tornare automaticamente a MASTER
    preempt_delay 10        # Aspetta 10 secondi prima di tornare a MASTER
    garp_master_delay 1     # Invia subito i gratuitous ARP in stato MASTER
 
    track_script {
        chk_eth1
    }

    # Qui usiamo "notify" globale, che supporta up/down
    notify "$SCRIPT_DIR/keepalived-failover-handler.sh"
}
EOF

# Configurazione e avvio del servizio keepalived
print_info "Configurazione e avvio del servizio keepalived..."
systemctl enable keepalived
systemctl restart keepalived

# Creazione della connessione 1nce con nmcli
print_info "Creazione della connessione 1nce usando nmcli..."

# Verificare se NetworkManager è installato
if ! command -v nmcli &> /dev/null; then
    print_warning "NetworkManager non trovato. Installazione in corso..."
    apt-get install -y network-manager
fi

# Verificare se la connessione esiste già
if nmcli connection show | grep -q "1nce"; then
    print_warning "Connessione 1nce già esistente. Rimozione della connessione precedente..."
    nmcli connection delete 1nce
fi

# Creare la connessione gsm
print_info "Creazione della connessione mobile 1nce..."
nmcli connection add \
    type gsm \
    con-name 1nce \
    ifname cdc-wdm0 \
    apn $APN \
    autoconnect yes

# Attivare la connessione
print_info "Attivazione della connessione 1nce..."
nmcli connection up 1nce

# Attendere alcuni secondi per permettere alla connessione di stabilirsi
print_info "Attendo che la connessione si stabilizzi..."
sleep 10

# Recuperare l'indirizzo IP dell'interfaccia secondaria
print_info "Recupero dell'indirizzo IP dell'interfaccia $SECONDARY_INTERFACE..."
SECONDARY_IP=$(ip addr show $SECONDARY_INTERFACE | grep -oP 'inet \K[\d.]+')

if [ -z "$SECONDARY_IP" ]; then
    print_warning "Non è stato possibile recuperare l'indirizzo IP di $SECONDARY_INTERFACE. Utilizzo del gateway come IP."
    SECONDARY_IP=$SECONDARY_GATEWAY
fi

print_info "Indirizzo IP rilevato per $SECONDARY_INTERFACE: $SECONDARY_IP"
read -p "Vuoi modificare l'indirizzo IP dell'interfaccia secondaria? [$SECONDARY_IP]: " NEW_SECONDARY_IP
SECONDARY_IP=${NEW_SECONDARY_IP:-$SECONDARY_IP}

# Richiedi l'indirizzo IP della VPN o altro endpoint da raggiungere attraverso la connessione secondaria
read -p "Inserisci l'indirizzo IP o la rete di destinazione per la rotta statica [10.65.235.233/32]: " VPN_DEST
VPN_DEST=${VPN_DEST:-"10.65.235.233/32"}

# Aggiungere la rotta statica alla connessione
print_info "Aggiunta della rotta statica via $SECONDARY_IP alla connessione 1nce per la VPN..."
nmcli connection modify 1nce +ipv4.routes "$VPN_DEST $SECONDARY_IP"

# Verifica finale
print_info "Verifica dello stato dei servizi..."

if systemctl is-active --quiet keepalived; then
    print_info "Servizio keepalived avviato correttamente."
else
    print_error "Errore nell'avvio del servizio keepalived."
fi

if nmcli connection show --active | grep -q "1nce"; then
    print_info "Connessione 1nce attivata correttamente."
else
    print_warning "La connessione 1nce non risulta attiva. Verificare manualmente."
fi

print_info "Installazione completata!"
echo ""
echo "Configurazione summary:"
echo "- Interfaccia primaria: $PRIMARY_INTERFACE"
echo "- Interfaccia secondaria: $SECONDARY_INTERFACE"
echo "- IP monitorato con ping: $PING_IP"
echo "- Gateway primario: $PRIMARY_GATEWAY"
echo "- Gateway secondario: $SECONDARY_GATEWAY"
echo "- APN per connessione 1nce: $APN"
echo ""
echo "Script creati in $SCRIPT_DIR:"
echo "- check-eth1.sh"
echo "- keepalived-failover-handler.sh"
echo ""
echo "Per verificare lo stato, eseguire:"
echo "  systemctl status keepalived"
echo "  nmcli connection show --active"
echo "  ip route show"
