#!/bin/bash
set -e

# Whisper API - Install as system service
# Uso: ./install.sh
#
# Questo script gira da root. Regole (revisione di sicurezza del 2026-11-23,
# _kb/centralino.md):
# - root non esegue e non scrive niente in cartelle dell'utente del servizio
#   (conda, profili, /etc/qbert): lì si lavora con `sudo -u`;
# - $INSTALL_DIR è di root: il codice che il servizio esegue si cambia solo
#   rilanciando questo script;
# - nessun valore che finisce nell'unità systemd viene dall'output di una
#   shell dell'utente: solo costanti e percorsi letti da /etc/passwd;
# - /etc/sudoers.d/qbert non si tocca: lo genera per intero QBert/install.sh.

SERVICE_NAME="whisper-api"
SERVICE_USER="${SUDO_USER:-$USER}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/whisper-api"
CONDA_ENV_NAME="whisper-api"
PORT=8787
QBERT_KEY="whisper"
QBERT_CONFIG="/etc/qbert/services.json"

# Richiedi sudo all'inizio
if [ "$EUID" -ne 0 ]; then
	exec sudo bash "$0" "$@"
fi

die() {
	echo "ERRORE: $*" >&2
	exit 1
}

# L'utente del servizio finisce nell'unità systemd e nei comandi `sudo -u`:
# deve essere un nome semplice, esistere, e non essere root.
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "nome utente non valido: '$SERVICE_USER'"
SERVICE_UID="$(id -u "$SERVICE_USER" 2>/dev/null)" || die "l'utente $SERVICE_USER non esiste"
[ "$SERVICE_UID" -ne 0 ] || die "il servizio non gira come root: lancia ./install.sh dal tuo utente"
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
# La home si legge da /etc/passwd, non dall'ambiente né da una shell dell'utente.
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
[[ "$SERVICE_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "home di $SERVICE_USER non valida: '$SERVICE_HOME'"
CONDA_ENV="$SERVICE_HOME/.conda/envs/$CONDA_ENV_NAME"

as_svc() {
	sudo -u "$SERVICE_USER" "$@"
}

# Copia da root un file in una cartella di root, senza seguire link né in
# partenza né in arrivo: `cp` scriverebbe dentro il file a cui punta un link
# già presente nella destinazione.
copia_di_root() {
	[ -f "$1" ] && [ ! -L "$1" ] || die "$1 non è un file regolare"
	rm -f -- "$2"
	install -T -o root -g root -m 0644 -- "$1" "$2"
}

echo "=== Whisper API - Installazione servizio ==="
echo "Source: $SOURCE_DIR"
echo "Install dir: $INSTALL_DIR"
echo "Utente: $SERVICE_USER"
echo "Conda env: $CONDA_ENV"
echo ""

# Ambiente conda. Il percorso è fisso: non si chiede a conda (né a una shell
# dell'utente) dove sta, perché la risposta finirebbe nell'unità systemd.
if [ ! -d "$CONDA_ENV" ]; then
	CONDA_BIN=""
	for candidate in /opt/miniconda3 /opt/anaconda3 "$SERVICE_HOME/miniconda3" "$SERVICE_HOME/anaconda3"; do
		if [ -x "$candidate/bin/conda" ]; then
			CONDA_BIN="$candidate/bin/conda"
			break
		fi
	done
	[ -n "$CONDA_BIN" ] || die "conda non trovata (cercata in /opt e in $SERVICE_HOME)"
	echo "Creazione ambiente conda in $CONDA_ENV..."
	as_svc "$CONDA_BIN" create -p "$CONDA_ENV" python=3.11 -y
fi

# Installa dipendenze se mancano (pip gira con l'utente del servizio)
if [ ! -f "$CONDA_ENV/bin/uvicorn" ]; then
	echo "Installazione dipendenze..."
	as_svc "$CONDA_ENV/bin/pip" install -r "$SOURCE_DIR/requirements.txt"
fi

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

# Disabilita eventuale user service
echo "Disabilitazione eventuale user service..."
as_svc systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
as_svc systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true

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

# Registra il servizio in QBert services.json. Il file è dell'utente di QBert:
# lo apre e lo riscrive quell'utente, non root, senza seguire link (un link
# messo al posto del file farebbe scrivere altrove) e in modo atomico.
if [ -e "$QBERT_CONFIG" ] || [ -L "$QBERT_CONFIG" ]; then
	as_svc /usr/bin/python3 -I - "$QBERT_CONFIG" "$QBERT_KEY" "$PORT" "${SERVICE_NAME}.service" <<'PY' \
		|| echo "NOTA: $QBERT_CONFIG non aggiornato: aggiungi a mano la voce '$QBERT_KEY' e rilancia QBert/install.sh."
import json, os, sys, tempfile

path, key, port, unit = sys.argv[1:5]
try:
	fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as e:
	sys.exit(f"non apro {path}: {e}")
with os.fdopen(fd, encoding="utf-8") as f:
	cfg = json.load(f)
if not isinstance(cfg, dict):
	sys.exit(f"{path} non contiene un oggetto JSON")
if key in cfg:
	print(f"{key} già registrato in {path}.")
	sys.exit(0)
print(f"Registrazione {key} in {path}...")
cfg[key] = {
	"url": f"http://127.0.0.1:{port}",
	"free_vram": {"method": "POST", "path": "/unload", "json": {}},
	"systemd_unit": unit,
	"default_resource": "gpu",
	"default_priority": "normal",
	"startup_check": "/health",
	"startup_timeout": 30,
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".services.json.")
try:
	with os.fdopen(fd, "w", encoding="utf-8") as f:
		json.dump(cfg, f, indent="\t")
		f.write("\n")
	os.chmod(tmp, 0o644)
	os.replace(tmp, path)
except BaseException:
	os.unlink(tmp)
	raise
PY
else
	echo "NOTA: $QBERT_CONFIG non trovato, QBert non configurato."
fi

# Il permesso di restart per QBert (/etc/sudoers.d/qbert) non si scrive da
# qui: lo genera per intero QBert/install.sh partendo da services.json, con i
# nomi convalidati e il controllo di visudo.
echo "NOTA: se ${SERVICE_NAME}.service è nuovo in $QBERT_CONFIG, per il restart da QBert"
echo "      rilancia QBert/install.sh (rigenera /etc/sudoers.d/qbert)."

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
