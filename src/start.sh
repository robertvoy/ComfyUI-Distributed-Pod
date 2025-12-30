#!/usr/bin/env bash
set -euo pipefail

# Use libtcmalloc for better memory management
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

# ---------------------------------------------------------------------------
# OPTIMIZATION 1: Consolidated apt-get calls
# ---------------------------------------------------------------------------
PACKAGES=""
if ! which aria2 >/dev/null 2>&1; then PACKAGES="$PACKAGES aria2"; fi
if ! which curl >/dev/null 2>&1; then PACKAGES="$PACKAGES curl"; fi
if ! dpkg -s bash-completion >/dev/null 2>&1; then PACKAGES="$PACKAGES bash-completion"; fi

if [ -n "$PACKAGES" ]; then
  echo "Installing missing packages: $PACKAGES"
  apt-get update && apt-get install -y $PACKAGES
else
  echo "All system dependencies already installed."
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
echo "Updating ComfyUI..."
cd /ComfyUI && git pull && pip install -r requirements.txt

echo "Updating ComfyUI-Distributed..."
cd /ComfyUI/custom_nodes/ComfyUI-Distributed
# Branch switching logic
TARGET_BRANCH="${DISTRIBUTED_BRANCH:-main}"
echo "Switching ComfyUI-Distributed to branch: $TARGET_BRANCH"
git fetch origin
git checkout "$TARGET_BRANCH"
git pull origin "$TARGET_BRANCH"

echo "Updating WanVideoWrapper..."
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper && git pull && pip install -r requirements.txt
echo "Updating KJNodes..."
cd /ComfyUI/custom_nodes/ComfyUI-KJNodes && git pull && pip install -r requirements.txt

# Download a single file from a repo to an exact path (skip if present)
hf_get () {
  # $1=repo_id  $2=path_in_repo  $3=dest_file
  local repo="$1" rel="$2" dest="$3"
  local dest_dir; dest_dir="$(dirname "$dest")"

  # Skip if already present
  if [ -f "$dest" ]; then
    echo "Exists: $(basename "$dest")"
    return 0
  fi

  mkdir -p "$dest_dir"
  # Quietly download in background
  HF_HUB_ENABLE_HF_TRANSFER=1 hf download "$repo" \
    --include "$rel" --revision main --local-dir "$dest_dir" >/dev/null 2>&1

  local src="$dest_dir/$rel"
  if [ "$src" != "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    mv -f "$src" "$dest"
    rmdir -p "$(dirname "$src")" 2>/dev/null || true
  else
    echo "Downloaded: $(basename "$dest")"
  fi
}

# ---------------------------------------------------------------------------
# PRESET 1: VIDEO UPSCALER (Wan 2.2 T2V + Upscalers)
# ---------------------------------------------------------------------------
if [ "${PRESET_VIDEO_UPSCALER:-false}" != "false" ]; then
  echo "Preparing Video Upscaler Preset (Parallel)..."
  
  # Install Custom Node
  (
    cd /ComfyUI/custom_nodes/
    if [ ! -d "RES4LYF" ]; then git clone https://github.com/ClownsharkBatwing/RES4LYF/; fi
    cd RES4LYF && pip install -r requirements.txt
  ) &

  # Wan T2V Model
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" ) &

  # Shared: T5 Text Encoder
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors" ) &

  # Shared: VAE
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors" ) &

  # LoRA
  ( hf_get "Kijai/WanVideo_comfy" "Wan22-Lightning/Wan2.2-Lightning_T2V-v1.1-A14B-4steps-lora_LOW_fp16.safetensors" "/workspace/ComfyUI/models/loras/Wan2.2-Lightning_T2V-v1.1-A14B-4steps-lora_LOW_fp16.safetensors" ) &

  # Upscalers
  (
    hf_get "Phips/4xNomos8kDAT" "4xNomos8kDAT.safetensors" "/workspace/ComfyUI/models/upscale_models/4xNomos8kDAT.safetensors"
    hf_get "ai-forever/Real-ESRGAN" "RealESRGAN_x2.pth" "/workspace/ComfyUI/models/upscale_models/RealESRGAN_x2.pth"
  ) &

  wait
  echo "Video Upscaler Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET 2: WAN 2.2 FP16 I2V (High Quality Image-to-Video)
# ---------------------------------------------------------------------------
if [ "${PRESET_WAN2_2_FP16:-false}" != "false" ]; then
  echo "Preparing Wan 2.2 FP16 I2V Preset (Parallel)..."

  # Shared: T5 Text Encoder (Skips if downloaded by Preset 1)
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors" ) &

  # Shared: VAE (Skips if downloaded by Preset 1)
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors" ) &

  # I2V Low Noise Model (FP16)
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" ) &

  # I2V High Noise Model (FP16)
  ( hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" ) &

  # Distilled LoRAs (Grouped to avoid race conditions on same repo)
  (
    hf_get "lightx2v/Wan2.2-Distill-Loras" "wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"
    hf_get "lightx2v/Wan2.2-Distill-Loras" "wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors"
  ) &

  wait
  echo "Wan 2.2 FP16 I2V Preset: Complete."
fi

# Install Nunchaku if enabled
if [ "${NUNCHAKU:-true}" != "false" ]; then
  echo "Installing Nunchaku"
  (
    set -e
    
    cd /ComfyUI/custom_nodes
    if [ ! -d "ComfyUI-nunchaku" ]; then
      git clone https://github.com/nunchaku-tech/ComfyUI-nunchaku/
    else
      cd ComfyUI-nunchaku && git pull
    fi
    
    TORCH_VERSION=$(python -c "import torch; print(torch.__version__.split('+')[0][:3])")
    check_url() { curl --head --silent --fail "$1" > /dev/null 2>&1; }
    
    WHEEL_VERSION="1.1.0"
    WHEEL_BASE_URL="https://github.com/nunchaku-tech/nunchaku/releases/download/v${WHEEL_VERSION}"
    WHEEL_NAME="nunchaku-${WHEEL_VERSION}+torch${TORCH_VERSION}-cp312-cp312-linux_x86_64.whl"
    WHEEL_URL="${WHEEL_BASE_URL}/${WHEEL_NAME}"
    
    if check_url "${WHEEL_URL}"; then
      pip install "${WHEEL_URL}"
    else
      FALLBACK_VERSIONS="2.8 2.7 2.6 2.5 2.4 2.3"
      INSTALLED=false
      for VERSION in ${FALLBACK_VERSIONS}; do
        FALLBACK_URL="${WHEEL_BASE_URL}/nunchaku-1.0.0+torch${VERSION}-cp312-cp312-linux_x86_64.whl"
        if check_url "${FALLBACK_URL}"; then
          pip install "${FALLBACK_URL}"
          INSTALLED=true
          break
        fi
      done
      if [ "${INSTALLED}" = false ]; then echo "ERROR: No Nunchaku wheel found."; exit 1; fi
    fi
  )
fi

# Wait for SageAttention (if building)
if [ -n "${BUILD_PID:-}" ]; then
  echo "Waiting for SageAttention build..."
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 10
  done
fi

# Start ComfyUI
echo "Launching ComfyUI"
ARGS="--listen --enable-cors-header"
[ "${SAGE_ATTENTION:-true}" != "false" ] && ARGS="$ARGS --use-sage-attention"

nohup python3 "$COMFYUI_DIR/main.py" $ARGS > "/comfyui_${RUNPOD_POD_ID:-local}_nohup.log" 2>&1 &

until curl --silent --fail "$URL" --output /dev/null; do
  echo "Launching ComfyUI..."
  sleep 2
done
echo "ComfyUI is ready"
sleep infinity
