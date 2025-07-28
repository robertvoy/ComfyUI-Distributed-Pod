#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# Set the network volume path initially
NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

# Always use root directory as base, regardless of whether /workspace exists
echo "Setting NETWORK_VOLUME to '/' (root directory)."
NETWORK_VOLUME="/"
echo "Starting JupyterLab on root directory..."
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &

COMFYUI_DIR="/ComfyUI"
WORKFLOW_DIR="/ComfyUI/user/default/workflows"

# Set the target directory
CUSTOM_NODES_DIR="/ComfyUI/custom_nodes"

# Skip downloading CivitAI download script, custom nodes, and model downloads

# Skip building SageAttention

# Skip additional model downloads and upscale models

# Skip workflow copying (assuming it's not needed or can be skipped for simplification)

# Skip configuration updates for preview method

# Workspace as main working directory (but since base is root, adjust accordingly)
echo "cd $NETWORK_VOLUME" >> ~/.bashrc

# Skip dependency installations for custom nodes (since not installing them)

# Start ComfyUI
echo "▶️  Starting ComfyUI"
if [ "$enable_optimizations" = "false" ]; then
    python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header
else
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header > "$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
    until curl --silent --fail "$URL" --output /dev/null; do
      echo "🔄  ComfyUI Starting Up... You can view the startup logs here: $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"
      sleep 2
    done
    echo "🚀 ComfyUI is UP"
    sleep infinity
fi