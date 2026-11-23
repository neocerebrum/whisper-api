#!/bin/bash
set -e

# Whisper API - parte dell'UTENTE dell'installazione (senza sudo)
# Uso: ./prepara.sh
#
# Prepara quello che sta nella home e nelle cartelle dell'utente del servizio:
# ambiente conda, dipendenze, modelli, registrazione in QBert. La parte di
# root (codice in /opt, unità systemd, restart) è install.sh, da lanciare dopo.
# Serve alla prima installazione e quando cambia requirements.txt.

SERVICE_NAME="whisper-api"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/whisper-api"
CONDA_ENV_NAME="whisper-api"
CONDA_ENV="$HOME/.conda/envs/$CONDA_ENV_NAME"
PORT=8787
QBERT_KEY="whisper"
QBERT_CONFIG="/etc/qbert/services.json"

if [ "$EUID" -eq 0 ]; then
	echo "ERRORE: prepara.sh si lancia con l'utente del servizio, senza sudo."
	exit 1
fi

echo "=== Whisper API - preparazione (utente $USER) ==="
echo "Source: $SOURCE_DIR"
echo "Conda env: $CONDA_ENV"
echo ""

# Ambiente conda, a un percorso fisso: è quello scritto nell'unità systemd.
if [ ! -d "$CONDA_ENV" ]; then
	CONDA_BIN=""
	for candidate in /opt/miniconda3 /opt/anaconda3 "$HOME/miniconda3" "$HOME/anaconda3"; do
		if [ -x "$candidate/bin/conda" ]; then
			CONDA_BIN="$candidate/bin/conda"
			break
		fi
	done
	if [ -z "$CONDA_BIN" ]; then
		echo "ERRORE: conda non trovata (cercata in /opt e in $HOME)"
		exit 1
	fi
	echo "Creazione ambiente conda in $CONDA_ENV..."
	"$CONDA_BIN" create -p "$CONDA_ENV" python=3.11 -y
fi

# Installa dipendenze se mancano
if [ ! -f "$CONDA_ENV/bin/uvicorn" ]; then
	echo "Installazione dipendenze..."
	"$CONDA_ENV/bin/pip" install -r "$SOURCE_DIR/requirements.txt"
fi

# Disabilita eventuale user service
echo "Disabilitazione eventuale user service..."
systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true

# Registra il servizio in QBert services.json, se non c'è già. Il file è
# dell'utente di QBert: si apre senza seguire link e si riscrive in modo
# atomico.
if [ -e "$QBERT_CONFIG" ] || [ -L "$QBERT_CONFIG" ]; then
	/usr/bin/python3 -I - "$QBERT_CONFIG" "$QBERT_KEY" "$PORT" "${SERVICE_NAME}.service" <<'PY' \
		|| echo "NOTA: $QBERT_CONFIG non aggiornato: aggiungi a mano la voce '$QBERT_KEY'."
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
	echo "NOTA: se ${SERVICE_NAME}.service è nuovo in $QBERT_CONFIG, per il restart da QBert"
	echo "      rilancia QBert/install.sh (rigenera /etc/sudoers.d/qbert) e riavvia QBert."
else
	echo "NOTA: $QBERT_CONFIG non trovato, QBert non configurato."
fi

echo ""
echo "=== Preparazione completata ==="
echo "Ora la parte di root: ./install.sh"
