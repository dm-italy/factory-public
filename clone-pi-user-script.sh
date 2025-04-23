#!/bin/bash

# Script per clonare l'utente pi su Raspberry Pi
# Richiede privilegi di root per essere eseguito

# Verifica se lo script è eseguito come root
if [ "$(id -u)" -ne 0 ]; then
    echo "Questo script deve essere eseguito come root o con sudo."
    exit 1
fi

# Verifica se l'utente pi esiste
if ! id "pi" &>/dev/null; then
    echo "L'utente pi non esiste su questo sistema."
    exit 1
fi

# Richiedi il nome del nuovo utente
read -p "Inserisci il nome del nuovo utente: " NUOVO_UTENTE

# Verifica se il nome utente è valido (non vuoto e non contiene spazi)
if [ -z "$NUOVO_UTENTE" ] || [[ "$NUOVO_UTENTE" == *" "* ]]; then
    echo "Nome utente non valido. Non può essere vuoto e non può contenere spazi."
    exit 1
fi

# Verifica se l'utente esiste già
if id "$NUOVO_UTENTE" &>/dev/null; then
    echo "L'utente $NUOVO_UTENTE esiste già. Scegli un altro nome."
    exit 1
fi

echo "Creazione del nuovo utente $NUOVO_UTENTE..."

# Crea il nuovo utente
adduser $NUOVO_UTENTE

# Ottieni tutti i gruppi dell'utente pi e li assegna al nuovo utente
PI_GROUPS=$(groups pi | cut -d':' -f2 | sed 's/^ //')
echo "Aggiunta dell'utente $NUOVO_UTENTE ai gruppi: $PI_GROUPS"
for group in $PI_GROUPS; do
    usermod -a -G $group $NUOVO_UTENTE
done

# Copia dei file dalla home directory di pi
echo "Copia dei file dalla home di pi alla home di $NUOVO_UTENTE..."
cp -r /home/pi/. /home//$NUOVO_UTENTE/

# Correggi i permessi
echo "Correzione dei permessi..."
chown -R $NUOVO_UTENTE:$NUOVO_UTENTE /home/$NUOVO_UTENTE/

echo "Completato! L'utente $NUOVO_UTENTE è stato creato come clone di pi."
echo ""
echo "Vuoi disabilitare l'utente pi per motivi di sicurezza?"
read -p "Disabilitare l'utente pi? (s/n): " DISABILITA_PI

if [[ "$DISABILITA_PI" == "s" || "$DISABILITA_PI" == "S" ]]; then
    echo "Disabilitazione dell'utente pi..."
    passwd -l pi
    echo "L'utente pi è stato disabilitato. Puoi riattivarlo con 'sudo passwd -u pi' se necessario."
else
    echo "L'utente pi rimane attivo."
fi

echo ""
echo "Script completato con successo."
echo "Ora puoi accedere con il nuovo utente: $NUOVO_UTENTE"
