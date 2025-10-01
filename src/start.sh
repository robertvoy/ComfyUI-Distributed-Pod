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
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper && git pull && pip install -r requirements.txt
echo "Updating KJNodes."
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
  HF_HUB_ENABLE_HF_TRANSFER=1 hf download "$repo" \
    --include "$rel" --revision main --local-dir "$dest_dir"

  local src="$dest_dir/$rel"
  if [ "$src" != "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    mv -f "$src" "$dest"
    # remove empty nested dirs created by $rel (ignore if not empty)
    rmdir -p "$(dirname "$src")" 2>/dev/null || true
  else
    echo "Already at destination: $(basename "$dest")"
  fi
}

# Only prepare Video Upscaler Preset if enabled
if [ "${PRESET_VIDEO_UPSCALER:-true}" != "false" ]; then
  echo "Preparing Video Upscaler Preset"
  (
    cd /ComfyUI/custom_nodes/
    git clone https://github.com/ClownsharkBatwing/RES4LYF/ || true
    cd RES4LYF || exit 1
    pip install -r requirements.txt

    # WAN 2.2 diffusion model
    hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
      "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
      "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

    # Text encoder -> /models/clip
    hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
      "split_files/text_encoders/umt5_xxl_fp16.safetensors" \
      "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors"

    # VAE -> /models/vae
    hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
      "split_files/vae/wan_2.1_vae.safetensors" \
      "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors"

    # LoRA -> /models/loras
    hf_get "Kijai/WanVideo_comfy" \
      "Wan22-Lightning/Wan2.2-Lightning_T2V-v1.1-A14B-4steps-lora_LOW_fp16.safetensors" \
      "/workspace/ComfyUI/models/loras/Wan2.2-Lightning_T2V-v1.1-A14B-4steps-lora_LOW_fp16.safetensors"

    # Upscaler -> /models/upscale_models
    hf_get "Phips/4xNomos8kDAT" \
      "4xNomos8kDAT.safetensors" \
      "/workspace/ComfyUI/models/upscale_models/4xNomos8kDAT.safetensors"
      
    # Upscaler 2 -> /models/upscale_models
    hf_get "ai-forever/Real-ESRGAN" \
      "RealESRGAN_x2.pth" \
      "/workspace/ComfyUI/models/upscale_models/RealESRGAN_x2.pth"
  )
fi

# Install Nunchaku if enabled
if [ "${NUNCHAKU:-true}" != "false" ]; then
  echo "Installing Nunchaku"
  (
    set -e
    
    # Clone the ComfyUI-nunchaku repository
    cd /ComfyUI/custom_nodes
    if [ ! -d "ComfyUI-nunchaku" ]; then
      git clone https://github.com/nunchaku-tech/ComfyUI-nunchaku/
      echo "ComfyUI-nunchaku cloned successfully"
    else
      echo "ComfyUI-nunchaku already exists, updating..."
      cd ComfyUI-nunchaku && git pull
    fi
    
    # Detect PyTorch version
    TORCH_VERSION=$(python -c "import torch; print(torch.__version__.split('+')[0][:3])")
    echo "Detected PyTorch version: ${TORCH_VERSION}"
    
    # Function to check if URL exists
    check_url() {
      curl --head --silent --fail "$1" > /dev/null 2>&1
    }
    
    # Base URL and construct wheel URL
    WHEEL_VERSION="1.0.1"
    WHEEL_BASE_URL="https://github.com/nunchaku-tech/nunchaku/releases/download/v${WHEEL_VERSION}"
    WHEEL_NAME="nunchaku-${WHEEL_VERSION}+torch${TORCH_VERSION}-cp312-cp312-linux_x86_64.whl"
    WHEEL_URL="${WHEEL_BASE_URL}/${WHEEL_NAME}"
    
    # Check if wheel exists for detected version
    echo "Checking for Nunchaku wheel for PyTorch ${TORCH_VERSION}..."
    if check_url "${WHEEL_URL}"; then
      echo "Found wheel for PyTorch ${TORCH_VERSION}, installing..."
      pip install "${WHEEL_URL}"
      echo "Nunchaku installation successful"
    else
      # Try common fallback versions in order
      echo "No wheel found for PyTorch ${TORCH_VERSION}, trying fallback versions..."
      FALLBACK_VERSIONS="2.8 2.7 2.6 2.5 2.4 2.3"
      
      INSTALLED=false
      for VERSION in ${FALLBACK_VERSIONS}; do
        FALLBACK_URL="${WHEEL_BASE_URL}/nunchaku-1.0.0+torch${VERSION}-cp312-cp312-linux_x86_64.whl"
        if check_url "${FALLBACK_URL}"; then
          echo "Found fallback wheel for PyTorch ${VERSION}, installing..."
          pip install "${FALLBACK_URL}"
          echo "Nunchaku installed using PyTorch ${VERSION} wheel (fallback)"
          INSTALLED=true
          break
        fi
      done
      
      if [ "${INSTALLED}" = false ]; then
        echo "ERROR: Could not find compatible Nunchaku wheel. Please check available versions."
        exit 1
      fi
    fi
    
    echo "Nunchaku installation complete"
  )
else
  echo "Nunchaku disabled, skipping installation"
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
