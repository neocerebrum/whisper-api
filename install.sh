#!/bin/bash
set -e

# Whisper API - Install as system service
# Uso: ./install.sh

SERVICE_NAME="whisper-api"
SERVICE_USER="${SUDO_USER:-$USER}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/whisper-api"
PORT=8787
QBERT_SUDOERS="/etc/sudoers.d/qbert"
QBERT_CONFIG="/etc/qbert/services.json"

# Richiedi sudo all'inizio
if [ "$EUID" -ne 0 ]; then
	exec sudo bash "$0" "$@"
fi

# Trova conda nell'ambiente dell'utente
CONDA_BASE="$(sudo -u "$SERVICE_USER" bash -lc "conda info --base 2>/dev/null")" || true
if [ -z "$CONDA_BASE" ]; then
	echo "ERRORE: conda non trovata per l'utente $SERVICE_USER"
	exit 1
fi
CONDA_ENV="$CONDA_BASE/envs/whisper-api"

echo "=== Whisper API - Installazione servizio ==="
echo "Source: $SOURCE_DIR"
echo "Install dir: $INSTALL_DIR"
echo "Utente: $SERVICE_USER"
echo "Conda env: $CONDA_ENV"
echo ""

# Crea conda env se non esiste
if [ ! -d "$CONDA_ENV" ]; then
	echo "Creazione ambiente conda whisper-api..."
	sudo -u "$SERVICE_USER" bash -lc "conda create -n whisper-api python=3.11 -y"
fi

# Installa dipendenze se mancano
if [ ! -f "$CONDA_ENV/bin/uvicorn" ]; then
	echo "Installazione dipendenze..."
	sudo -u "$SERVICE_USER" "$CONDA_ENV/bin/pip" install -r "$SOURCE_DIR/requirements.txt"
fi

# Copia file in /opt
echo "Copia file in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp "$SOURCE_DIR/server.py" "$INSTALL_DIR/"
cp "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Disabilita eventuale user service
echo "Disabilitazione eventuale user service..."
sudo -u "$SERVICE_USER" bash -c '
	systemctl --user stop whisper-api 2>/dev/null || true
	systemctl --user disable whisper-api 2>/dev/null || true
' || true

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

# Registra whisper in QBert services.json
if [ -f "$QBERT_CONFIG" ]; then
	if python3 -c "import json,sys; cfg=json.load(open('$QBERT_CONFIG')); sys.exit(0 if 'whisper' in cfg else 1)" 2>/dev/null; then
		echo "Whisper già registrato in $QBERT_CONFIG."
	else
		echo "Registrazione whisper in $QBERT_CONFIG..."
		python3 -c "
import json
with open('$QBERT_CONFIG') as f:
    cfg = json.load(f)
cfg['whisper'] = {
    'url': 'http://127.0.0.1:$PORT',
    'free_vram': {
        'method': 'POST',
        'path': '/unload',
        'json': {}
    },
    'systemd_unit': '${SERVICE_NAME}.service',
    'default_resource': 'gpu',
    'default_priority': 'normal',
    'startup_check': '/health',
    'startup_timeout': 30
}
with open('$QBERT_CONFIG', 'w') as f:
    json.dump(cfg, f, indent='\t')
    f.write('\n')
"
	fi
else
	echo "NOTA: $QBERT_CONFIG non trovato, QBert non configurato."
fi

# Aggiorna sudoers di QBert (se esiste)
if [ -f "$QBERT_SUDOERS" ]; then
	RESTART_RULE="qbert ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${SERVICE_NAME}.service"
	if ! grep -qF "$RESTART_RULE" "$QBERT_SUDOERS"; then
		echo "Aggiunta regola sudoers per QBert..."
		echo "$RESTART_RULE" >> "$QBERT_SUDOERS"
		chmod 440 "$QBERT_SUDOERS"
	else
		echo "Regola sudoers per QBert già presente."
	fi
else
	echo "NOTA: $QBERT_SUDOERS non trovato, sudoers non aggiornato."
	echo "Riesegui install.sh di QBert per rigenerare le regole."
fi

# Reload, abilita e avvia
echo "Avvio servizio..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo ""
echo "=== Installazione completata ==="
echo ""
echo "Comandi utili:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
echo "  curl http://127.0.0.1:$PORT/health"
echo ""
