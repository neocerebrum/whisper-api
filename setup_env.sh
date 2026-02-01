#!/bin/bash
set -e

ENV_NAME="whisper-api"

if conda env list | grep -q "^${ENV_NAME} "; then
    echo "Env '${ENV_NAME}' already exists, skipping creation."
else
    conda create -n "$ENV_NAME" python=3.11 -y
fi

eval "$(conda shell.bash hook)"
conda activate "$ENV_NAME"
pip install -r requirements.txt
echo "Done. Activate with: conda activate $ENV_NAME"
