# Whisper API

Servizio REST per speech-to-text basato su [OpenAI Whisper](https://github.com/openai/whisper), con supporto multi-modello dinamico e gestione VRAM. Integrato con [QBert](../QBert/) per la gestione GPU condivisa.

## Installazione

### 1. Crea l'ambiente conda

```bash
bash setup_env.sh
```

### 2. Installa come servizio di sistema

```bash
./install.sh
```

Lo script (chiede la password sudo) esegue:

- Copia `server.py` in `/opt/whisper-api/`
- Crea il systemd service `/etc/systemd/system/whisper-api.service`
- Registra il servizio in `/etc/qbert/services.json` (se QBert e installato)
- Aggiunge la regola sudoers per QBert
- Abilita e avvia il servizio

### Gestione servizio

```bash
sudo systemctl status whisper-api
sudo systemctl restart whisper-api
sudo systemctl stop whisper-api
journalctl -u whisper-api -f          # log live
```

## API

Porta: **8787** (locale) | Via QBert: `https://qbert.neocerebrum.work/whisper/`

### `GET /health`

Stato del servizio.

```bash
curl http://127.0.0.1:8787/health
```

```json
{
  "status": "ok",
  "model": "large-v3",
  "model_status": "loaded",
  "available_models": ["tiny", "base", "small", "medium", "large-v3", "..."],
  "vram": {"allocated_mb": 6017.6, "reserved_mb": 9374.0},
  "model_loaded_since": 120.5
}
```

### `POST /transcribe`

Trascrivi un file audio. Supporta wav, mp3, flac, ogg, m4a e altri formati supportati da ffmpeg.

**Parametri:**

| Parametro    | Tipo   | Default       | Descrizione                                |
|--------------|--------|---------------|--------------------------------------------|
| `file`       | file   | *obbligatorio*| File audio da trascrivere                  |
| `language`   | string | auto-detect   | Codice lingua (`it`, `en`, `de`, ...)      |
| `task`       | string | `transcribe`  | `transcribe` o `translate` (traduce in EN) |
| `model_name` | string | ultimo caricato | Modello Whisper da usare               |

**Esempi:**

```bash
# Trascrizione base (usa il modello corrente)
curl -F "file=@audio.wav" http://127.0.0.1:8787/transcribe

# Specifica lingua
curl -F "file=@audio.wav" "http://127.0.0.1:8787/transcribe?language=it"

# Usa un modello diverso (viene caricato al volo)
curl -F "file=@audio.wav" "http://127.0.0.1:8787/transcribe?model_name=base"

# Traduci in inglese
curl -F "file=@audio.wav" "http://127.0.0.1:8787/transcribe?task=translate"

# Via QBert
curl -F "file=@audio.wav" "https://qbert.neocerebrum.work/whisper/transcribe?language=it"
```

**Risposta:**

```json
{
  "text": "Testo trascritto completo",
  "segments": [
    {"id": 0, "start": 0.0, "end": 2.32, "text": "Primo segmento"},
    {"id": 1, "start": 3.12, "end": 4.82, "text": "Secondo segmento"}
  ],
  "language": "it",
  "model": "large-v3"
}
```

### `POST /unload`

Scarica il modello dalla VRAM. Usato da QBert per liberare la GPU quando serve ad altri servizi. Il modello viene ricaricato automaticamente alla prossima `/transcribe`.

```bash
curl -X POST http://127.0.0.1:8787/unload
```

```json
{"status": "unloaded", "vram_freed": true, "vram": {"allocated_mb": 9.1, "reserved_mb": 16.0}}
```

## Modelli

Il modello si cambia al volo passando `model_name` a `/transcribe`. Se il modello richiesto e diverso da quello in memoria, il vecchio viene scaricato e il nuovo caricato automaticamente.

| Modello     | VRAM   | Note                          |
|-------------|--------|-------------------------------|
| `tiny`      | ~1 GB  | Veloce, bassa qualita         |
| `base`      | ~1 GB  | Buon compromesso per test     |
| `small`     | ~2 GB  | Qualita discreta              |
| `medium`    | ~5 GB  | Buona qualita                 |
| `large-v3`  | ~6 GB  | Massima qualita (default)     |

Per la lista completa dei modelli disponibili, controlla `/health`.

## Struttura

```
whisper-api/
├── server.py          # Server FastAPI
├── requirements.txt   # Dipendenze Python
├── setup_env.sh       # Creazione ambiente conda
├── install.sh         # Installazione servizio di sistema
└── README.md
```

Dopo l'installazione, il servizio gira da `/opt/whisper-api/` ed e indipendente da questa directory.
