import gc
import tempfile
import time
from pathlib import Path

import torch
import whisper
from fastapi import FastAPI, File, UploadFile, Query
from fastapi.responses import JSONResponse

app = FastAPI(title="Whisper STT API")

AVAILABLE_MODELS = whisper.available_models()
DEFAULT_MODEL = "large-v3"
current_model_name = None
model = None
model_loaded_at = None


def get_vram_usage():
    if torch.cuda.is_available():
        allocated = torch.cuda.memory_allocated() / 1024**2
        reserved = torch.cuda.memory_reserved() / 1024**2
        return {"allocated_mb": round(allocated, 1), "reserved_mb": round(reserved, 1)}
    return {"allocated_mb": 0, "reserved_mb": 0}


def load_model(name: str = None):
    global model, model_loaded_at, current_model_name
    name = name or DEFAULT_MODEL
    if model is not None and current_model_name == name:
        return model
    if model is not None:
        del model
        model = None
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    model = whisper.load_model(name, device="cuda")
    current_model_name = name
    model_loaded_at = time.time()
    return model


@app.on_event("startup")
def startup():
    load_model(DEFAULT_MODEL)


@app.get("/health")
def health():
    status = "loaded" if model is not None else "unloaded"
    info = {
        "status": "ok",
        "model": current_model_name,
        "model_status": status,
        "available_models": AVAILABLE_MODELS,
        "vram": get_vram_usage(),
    }
    if model_loaded_at:
        info["model_loaded_since"] = round(time.time() - model_loaded_at, 1)
    return info


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    language: str = Query(None, description="Language code (e.g. 'it', 'en')"),
    task: str = Query("transcribe", description="'transcribe' or 'translate'"),
    model_name: str = Query(None, description="Whisper model to use (e.g. 'base', 'medium', 'large-v3')"),
):
    if model_name and model_name not in AVAILABLE_MODELS:
        return JSONResponse(
            status_code=400,
            content={"error": f"model '{model_name}' not available", "available": AVAILABLE_MODELS},
        )
    m = load_model(model_name)

    suffix = Path(file.filename).suffix if file.filename else ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp.flush()

        options = {"task": task}
        if language:
            options["language"] = language

        result = m.transcribe(tmp.name, **options)

    segments = [
        {
            "id": s["id"],
            "start": round(s["start"], 2),
            "end": round(s["end"], 2),
            "text": s["text"].strip(),
        }
        for s in result["segments"]
    ]

    return {
        "text": result["text"].strip(),
        "segments": segments,
        "language": result["language"],
        "model": current_model_name,
    }


@app.post("/unload")
def unload():
    global model, model_loaded_at, current_model_name
    if model is None:
        return {"status": "already_unloaded", "vram_freed": False}

    del model
    model = None
    current_model_name = None
    model_loaded_at = None
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    return {"status": "unloaded", "vram_freed": True, "vram": get_vram_usage()}
