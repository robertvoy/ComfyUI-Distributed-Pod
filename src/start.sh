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

URL="http://127.0.0.1:8188"
COMFYUI_DIR="/ComfyUI"
WORKFLOW_DIR="/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="/ComfyUI/custom_nodes"

echo "Starting JupyterLab on root directory..."
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &

# Copy workflows from ComfyUI-Distributed-Pod
SOURCE_WORKFLOW_DIR="workspace/ComfyUI-Distributed-Pod/workflows"
if [ -d "$SOURCE_WORKFLOW_DIR" ]; then
    cp -r "$SOURCE_WORKFLOW_DIR/"* "$WORKFLOW_DIR/"
    echo "Workflows copied successfully."
else
    echo "Workflow source directory not found: $SOURCE_WORKFLOW_DIR"
fi

# Copy extra_model_paths.yaml
SOURCE_YAML="workspace/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml"
if [ -f "$SOURCE_YAML" ]; then
    cp "$SOURCE_YAML" "$COMFYUI_DIR/extra_model_paths.yaml"
    echo "extra_model_paths.yaml copied successfully."
else
    echo "YAML source file not found: $SOURCE_YAML. Creating from provided contents..."
    cat <<EOL > "$COMFYUI_DIR/extra_model_paths.yaml"
comfyui:
      base_path: workspace/ComfyUI
      is_default: true
      BiRefNet: models/BiRefNet/
      checkpoints: models/checkpoints/
      clip: models/clip/
      clip_vision: models/clip_vision/
      configs: models/configs/
      controlnet: models/controlnet/
      diffusers: models/diffusers/
      diffusion_models: models/diffusion_models/
      embeddings: models/embeddings/
      florence2: models/florence2/
      facerestore_models: models/facerestore_models/
      gligen: models/gligen/
      grounding-dino: models/grounding-dino/
      hypernetworks: models/hypernetworks/
      ipadapter: models/ipadapter/
      lama: models/lama/
      loras: models/loras/
      onnx: models/onnx/
      photomaker: models/photomaker/
      RMBG: models/RMBG/
      sams: models/sams/
      style_models: models/style_models/
      text_encoders: models/text_encoders/
      unet: models/unet/
      upscale_models: models/upscale_models/
      vae: models/vae/
      vae_approx: models/vae_approx/
      vitmatte: models/vitmatte/
EOL
fi

# Create directories based on extra_model_paths.yaml
YAML_FILE="$COMFYUI_DIR/extra_model_paths.yaml"
if [ -f "$YAML_FILE" ]; then
    mkdir -p "/workspace/ComfyUI"
    grep 'models/' "$YAML_FILE" | awk -F': ' '{print $2}' | sed 's/\/$//' | while read -r dir; do
        if [ -n "$dir" ]; then
            mkdir -p "/workspace/ComfyUI/$dir"
        fi
    done
    echo "Model directories created in /workspace/ComfyUI."
else
    echo "extra_model_paths.yaml not found. Skipping directory creation."
fi

# Skip downloading CivitAI download script, custom nodes, and model downloads

# Skip building SageAttention

# Skip additional model downloads and upscale models

# Skip workflow copying (assuming it's not needed or can be skipped for simplification)

# Skip configuration updates for preview method

# Root as main working directory and update prompt
echo "cd /" >> ~/.bashrc
echo 'export PS1="\u@\h:\w# "' >> ~/.bashrc

# Start ComfyUI
echo "▶️  Starting ComfyUI"
if [ "$enable_optimizations" = "false" ]; then
    python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header
else
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
    until curl --silent --fail "$URL" --output /dev/null; do
      echo "🔄  ComfyUI Starting Up... You can view the startup logs here: /comfyui_${RUNPOD_POD_ID}_nohup.log"
      sleep 2
    done
    echo "🚀 ComfyUI is UP"
    sleep infinity
fi