#!/bin/bash
set -e

# Whisper API - parte di ROOT dell'installazione
# Uso: ./install.sh   (chiede sudo da sola)
#
# Copia il codice in $INSTALL_DIR, installa l'unità systemd, riavvia il
# servizio. La parte dell'utente (ambiente conda, pip, modelli, registrazione
# in QBert) è prepara.sh e si lancia prima, senza sudo.
#
# Regole (revisione di sicurezza del 2026-11-23, _kb/centralino.md):
# - $INSTALL_DIR è di root e i file si copiano senza seguire link;
# - questo script non legge, non esegue e non scrive niente nella home
#   dell'utente: l'ambiente conda compare solo come testo nell'unità, e lo
#   esegue systemd con User= dell'utente;
# - nessun valore dell'unità viene dall'output di una shell dell'utente:
#   solo costanti e la home letta da /etc/passwd;
# - /etc/sudoers.d/qbert e /etc/qbert/services.json non si toccano da qui.

SERVICE_NAME="whisper-api"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$USER}}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/whisper-api"
CONDA_ENV_NAME="whisper-api"
PORT=8787

if [ "$EUID" -ne 0 ]; then
	exec sudo bash "$0" "$@"
fi

die() {
	echo "ERRORE: $*" >&2
	exit 1
}

# L'utente del servizio finisce nell'unità systemd: nome semplice, esistente,
# mai root.
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "nome utente non valido: '$SERVICE_USER'"
SERVICE_UID="$(id -u "$SERVICE_USER" 2>/dev/null)" || die "l'utente $SERVICE_USER non esiste"
[ "$SERVICE_UID" -ne 0 ] || die "il servizio non gira come root: lancia ./install.sh dal tuo utente"
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
# La home si legge da /etc/passwd, non dall'ambiente né da una shell dell'utente.
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
[[ "$SERVICE_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "home di $SERVICE_USER non valida: '$SERVICE_HOME'"
CONDA_ENV="$SERVICE_HOME/.conda/envs/$CONDA_ENV_NAME"

# Copia da root un file in una cartella di root, senza seguire link né in
# partenza né in arrivo: `cp` scriverebbe dentro il file a cui punta un link
# già presente nella destinazione.
copia_di_root() {
	[ -f "$1" ] && [ ! -L "$1" ] || die "$1 non è un file regolare"
	rm -f -- "$2"
	install -T -o root -g root -m 0644 -- "$1" "$2"
}

echo "=== Whisper API - Installazione (parte di root) ==="
echo "Source: $SOURCE_DIR"
echo "Install dir: $INSTALL_DIR"
echo "Utente: $SERVICE_USER"
echo "Conda env (solo nell'unità): $CONDA_ENV"
echo ""

# Copia file in /opt. La cartella diventa di root prima di scriverci: da quel
# momento nessun altro può metterci un link.
echo "Copia file in $INSTALL_DIR..."
[ ! -L "$INSTALL_DIR" ] || die "$INSTALL_DIR è un link"
mkdir -p "$INSTALL_DIR"
chown -h root:root "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR"
# Bytecode lasciato da quando la cartella era dell'utente: Python lo
# caricherebbe al posto del sorgente. Il servizio non può più riscriverlo.
rm -rf -- "$INSTALL_DIR/__pycache__"
copia_di_root "$SOURCE_DIR/server.py" "$INSTALL_DIR/server.py"
copia_di_root "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

# Crea systemd service
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
echo "Creazione $SERVICE_FILE..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Whisper STT API Service
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$CONDA_ENV/bin/uvicorn server:app --host 127.0.0.1 --port $PORT
Restart=on-failure
Environment=CUDA_VISIBLE_DEVICES=0

[Install]
WantedBy=multi-user.target
EOF

# Reload, abilita e riavvia: `restart`, non `start`, così il codice nuovo
# entra anche se il servizio era già attivo.
echo "Riavvio servizio..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo ""
echo "=== Installazione completata ==="
echo ""
echo "Se il servizio non parte, manca la parte dell'utente: ./prepara.sh (senza sudo)."
echo ""
echo "Comandi utili:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
echo "  curl http://127.0.0.1:$PORT/health"
echo ""
