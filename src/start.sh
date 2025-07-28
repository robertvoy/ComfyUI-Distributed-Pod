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

export SHELL=/bin/bash

# Create a basic .bashrc for root to show the directory in the prompt and enable full bash features
if [ ! -f /root/.bashrc ]; then
    cat <<EOF > /root/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.

# If not running interactively, don't do anything
[ -z "\$PS1" ] && return

# Set a fancy prompt (non-color, unless we know we "want" color)
PS1='\u@\h:\w\# '

# Enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi
EOF
    echo ".bashrc created for root."
fi

# Install bash-completion if not present (for advanced command completion; basic file/dir completion works without it)
if ! dpkg -s bash-completion > /dev/null 2>&1; then
    echo "Installing bash-completion..."
    apt-get update && apt-get install -y bash-completion
fi

echo "Starting JupyterLab on root directory..."
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &

# Copy workflows from ComfyUI-Distributed-Pod
mkdir -p "$WORKFLOW_DIR"
SOURCE_WORKFLOW_DIR="/workspace/ComfyUI-Distributed-Pod/workflows"
if [ -d "$SOURCE_WORKFLOW_DIR" ]; then
    cp -r "$SOURCE_WORKFLOW_DIR/"* "$WORKFLOW_DIR/"
    echo "Workflows copied successfully."
else
    echo "Workflow source directory not found: $SOURCE_WORKFLOW_DIR"
fi

# Copy extra_model_paths.yaml
SOURCE_YAML="/workspace/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml"
if [ -f "$SOURCE_YAML" ]; then
    cp "$SOURCE_YAML" "$COMFYUI_DIR/extra_model_paths.yaml"
    echo "extra_model_paths.yaml copied successfully."
else
    echo "YAML source file not found: $SOURCE_YAML. Creating from provided contents..."
    cat <<EOL > "$COMFYUI_DIR/extra_model_paths.yaml"
comfyui:
      base_path: /workspace/ComfyUI
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

# ComfyUI manager config

# Optional building SageAttention

# Start ComfyUI
echo "▶️  Starting ComfyUI"
if [ "$enable_optimizations" = "false" ]; then
    python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header
else
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
    until curl --silent --fail "$URL" --output /dev/null; do
      echo "ComfyUI Starting Up... You can view the startup logs here: /comfyui_${RUNPOD_POD_ID}_nohup.log"
      sleep 2
    done
    echo "ComfyUI is ready"
    sleep infinity
fi
