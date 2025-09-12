#!/usr/bin/env bash
set -euo pipefail

# Use libtcmalloc for better memory management (use full path)
TCMALLOC="$(ldconfig -p | awk '/libtcmalloc\.so\.[0-9]+/ {print $NF; exit}')"
[ -n "${TCMALLOC:-}" ] && export LD_PRELOAD="$TCMALLOC"

python3 -m pip install -U "huggingface_hub[cli]" hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HUB_DISABLE_XET=1
# export HF_DEBUG=1
[ -n "${HF_API_TOKEN:-}" ] && hf auth login --token "$HF_API_TOKEN" || true

# Optional user hook
if [ -f "/workspace/additional_params.sh" ]; then
  chmod +x /workspace/additional_params.sh
  echo "Executing additional_params.sh..."
  /workspace/additional_params.sh
else
  echo "additional_params.sh not found in /workspace. Skipping..."
fi

# Minimal deps
if ! which aria2 >/dev/null 2>&1; then
  apt-get update && apt-get install -y aria2
else
  echo "aria2 is already installed"
fi
if ! which curl >/dev/null 2>&1; then
  apt-get update && apt-get install -y curl
else
  echo "curl is already installed"
fi

URL="http://127.0.0.1:8188"
COMFYUI_DIR="/ComfyUI"
WORKFLOW_DIR="/ComfyUI/user/default/workflows"

export SHELL=/bin/bash

# Basic .bashrc for interactive shells
if [ ! -f /root/.bashrc ]; then
  cat <<'EOF' > /root/.bashrc
[ -z "$PS1" ] && return
PS1='\u@\h:\w\# '
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then . /etc/bash_completion; fi
EOF
  echo ".bashrc created for root."
fi

# Bash completion (optional nicety)
if ! dpkg -s bash-completion >/dev/null 2>&1; then
  apt-get update && apt-get install -y bash-completion
fi

echo "Starting JupyterLab on root directory..."
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &

# Model folders
echo "Creating model directories..."
mkdir -p /workspace/ComfyUI/models/{checkpoints,clip,vae,controlnet,diffusion_models,unet,loras,clip_vision,upscale_models}

# Build SageAttention if enabled
if [ "${SAGE_ATTENTION:-true}" != "false" ]; then
  echo "Building SageAttention in the background"
  (
    set -e
    git clone https://github.com/thu-ml/SageAttention.git || true
    cd SageAttention
    python3 setup.py install
    pip install --no-cache-dir triton
  ) &> /var/log/sage_build.log &
  BUILD_PID=$!
  echo "Background build started (PID: $BUILD_PID)"
else
  echo "sage_attention disabled, skipping SageAttention build"
  BUILD_PID=""
fi

# Copy workflows
mkdir -p "$WORKFLOW_DIR"
SOURCE_WORKFLOW_DIR="/ComfyUI-Distributed-Pod/workflows"
if [ -d "$SOURCE_WORKFLOW_DIR" ]; then
  cp -r "$SOURCE_WORKFLOW_DIR/"* "$WORKFLOW_DIR/"
  echo "Workflows copied successfully."
else
  echo "Workflow source directory not found: $SOURCE_WORKFLOW_DIR"
fi

# extra_model_paths.yaml
SOURCE_YAML="/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml"
if [ -f "$SOURCE_YAML" ]; then
  cp "$SOURCE_YAML" "$COMFYUI_DIR/extra_model_paths.yaml"
  echo "extra_model_paths.yaml copied successfully."
else
  cat > "$COMFYUI_DIR/extra_model_paths.yaml" <<'EOL'
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

# Update ComfyUI + nodes
cd /ComfyUI && git pull && pip install -r requirements.txt
echo "Updating ComfyUI-Distributed."
cd /ComfyUI/custom_nodes/ComfyUI-Distributed && git pull
echo "Updating WanVideoWrapper."
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper && git pull
echo "Updating KJNodes."
cd /ComfyUI/custom_nodes/ComfyUI-KJNodes && git pull

# ---------- Clean download helper (skip if present) ----------
get_if_missing () {
  # $1 = URL, $2 = DEST FILE
  local url="$1" dest="$2"
  if [ -f "$dest" ]; then
    echo "Exists: $(basename "$dest")"
  else
    mkdir -p "$(dirname "$dest")"
    hf download "$url" -o "$dest"
  fi
}
# ------------------------------------------------------------

# Video Upscaler preset + model downloads
if [ "${PRESET_VIDEO_UPSCALER:-true}" != "false" ]; then
  echo "Preparing Video Upscaler Preset"
  (
    cd /ComfyUI/custom_nodes/
    git clone https://github.com/ClownsharkBatwing/RES4LYF/ || true
    cd RES4LYF || exit 1
    pip install -r requirements.txt

    # WAN 2.2 diffusion model (Comfy-Org)
    get_if_missing \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
      "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

    # Text encoder (umt5_xxl_fp16.safetensors) -> /models/clip
    get_if_missing \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors" \
      "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors"

    # VAE -> /models/vae
    get_if_missing \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
      "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors"

    # LoRA (download, then rename)
    get_if_missing \
      "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" \
      "/workspace/ComfyUI/models/loras/low_noise_model.safetensors"

    if [ -f "/workspace/ComfyUI/models/loras/low_noise_model.safetensors" ] && \
       [ ! -f "/workspace/ComfyUI/models/loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors" ]; then
      mv /workspace/ComfyUI/models/loras/low_noise_model.safetensors \
         /workspace/ComfyUI/models/loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors
      echo "LoRA renamed successfully"
    else
      echo "LoRA already renamed or not downloaded yet"
    fi

    # Upscaler model -> /models/upscale_models
    get_if_missing \
      "https://huggingface.co/Phips/4xNomos8kDAT/resolve/main/4xNomos8kDAT.safetensors" \
      "/workspace/ComfyUI/models/upscale_models/4xNomos8kDAT.safetensors"
  )
fi

# Wait for SageAttention (if building)
if [ -n "${BUILD_PID:-}" ]; then
  echo "Waiting for SageAttention build to complete..."
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    echo "SageAttention build in progress... (this can take up to 5 minutes)"
    sleep 10
  done
  echo "SageAttention build complete"
fi

# Start ComfyUI
echo "Launching ComfyUI"
if [ "${SAGE_ATTENTION:-true}" = "false" ]; then
  nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header > "/comfyui_${RUNPOD_POD_ID:-local}_nohup.log" 2>&1 &
else
  nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header --use-sage-attention > "/comfyui_${RUNPOD_POD_ID:-local}_nohup.log" 2>&1 &
fi

until curl --silent --fail "$URL" --output /dev/null; do
  echo "Launching ComfyUI"
  sleep 2
done
echo "ComfyUI is ready"
sleep infinity
