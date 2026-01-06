#!/usr/bin/env bash
set -euo pipefail

ulimit -n 65535 || true

TCMALLOC="$(ldconfig -p | awk '/libtcmalloc\.so\.[0-9]+/ {print $NF; exit}')"
[ -n "${TCMALLOC:-}" ] && export LD_PRELOAD="$TCMALLOC"

python3 -m pip install --upgrade "huggingface_hub[cli]" hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HUB_DISABLE_XET=1
export PYTHONUNBUFFERED=1
export GIT_TERMINAL_PROMPT=0
export GIT_MERGE_AUTOEDIT=no

[ -n "${HF_API_TOKEN:-}" ] && hf auth login --token "$HF_API_TOKEN" || true

# User Hook
if [ -f "/workspace/additional_params.sh" ]; then
  chmod +x /workspace/additional_params.sh
  /workspace/additional_params.sh
fi

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
PACKAGES=""
if ! which curl >/dev/null 2>&1; then PACKAGES="$PACKAGES curl"; fi
if ! which tail >/dev/null 2>&1; then PACKAGES="$PACKAGES coreutils"; fi
if ! dpkg -s bash-completion >/dev/null 2>&1; then PACKAGES="$PACKAGES bash-completion"; fi

if [ -n "$PACKAGES" ]; then
  echo "Installing missing packages: $PACKAGES"
  dpkg --configure -a || true
  apt-get update && apt-get install -y $PACKAGES
fi

URL="http://127.0.0.1:8188"
COMFYUI_DIR="/ComfyUI"
WORKFLOW_DIR="/ComfyUI/user/default/workflows"

# Start Jupyter (Background)
if ! pgrep -f "jupyter-lab" > /dev/null; then
  jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
fi

# Directories
mkdir -p /workspace/ComfyUI/models/{checkpoints,clip,vae,controlnet,diffusion_models,unet,loras,clip_vision,upscale_models,sam3}

# ---------------------------------------------------------------------------
# Copy workflows & Configs
# ---------------------------------------------------------------------------
mkdir -p "$WORKFLOW_DIR"
if [ -d "/ComfyUI-Distributed-Pod/workflows" ]; then
  cp -r "/ComfyUI-Distributed-Pod/workflows/"* "$WORKFLOW_DIR/"
fi

if [ -f "/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml" ]; then
  cp "/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml" "$COMFYUI_DIR/extra_model_paths.yaml"
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
  sam3: models/sam3/
  style_models: models/style_models/
  text_encoders: models/text_encoders/
  unet: models/unet/
  upscale_models: models/upscale_models/
  vae: models/vae/
  vae_approx: models/vae_approx/
  vitmatte: models/vitmatte/
EOL
fi

# ---------------------------------------------------------------------------
# REPO UPDATES & INSTALLS
# ---------------------------------------------------------------------------

# Helper function to clone/update nodes and install requirements
update_node() {
    local url="$1"
    local repo_name=$(basename "$url" .git)
    local target_dir="/ComfyUI/custom_nodes/$repo_name"

    echo "Updating $repo_name..."
    if [ -d "$target_dir" ]; then
        ( cd "$target_dir" && git pull )
    else
        git clone "$url" "$target_dir"
    fi

    # Only install requirements if the file actually exists
    if [ -f "$target_dir/requirements.txt" ]; then
        ( cd "$target_dir" && pip install -r requirements.txt )
    fi
}

echo "Updating ComfyUI Core..."
( cd /ComfyUI && git pull && pip install -r requirements.txt )

# Special handling for ComfyUI-Distributed (Branch selection)
echo "Updating ComfyUI-Distributed..."
if [ -d "/ComfyUI/custom_nodes/ComfyUI-Distributed" ]; then
    ( 
      cd "/ComfyUI/custom_nodes/ComfyUI-Distributed"
      git fetch origin
      git checkout "${DISTRIBUTED_BRANCH:-main}"
      git pull origin "${DISTRIBUTED_BRANCH:-main}"
    )
else
    git clone https://github.com/robertvoy/ComfyUI-Distributed.git /ComfyUI/custom_nodes/ComfyUI-Distributed
    ( cd /ComfyUI/custom_nodes/ComfyUI-Distributed && git checkout "${DISTRIBUTED_BRANCH:-main}" )
fi

# Conditional Install for Inpaint CropAndStitch
if [ "${CROP_STITCH_FORK:-false}" == "true" ]; then
    # Use your fork if variable is set
    update_node "https://github.com/robertvoy/ComfyUI-Inpaint-CropAndStitch.git"
else
    # Default to original repo
    update_node "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git"
fi

# ---------------------------------------------------------------------------
# Standard Node Installs
# ---------------------------------------------------------------------------

update_node "https://github.com/kijai/ComfyUI-KJNodes.git"
update_node "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"

# ---------------------------------------------------------------------------
# SAGEATTENTION BUILD
# ---------------------------------------------------------------------------
if [ "${SAGE_ATTENTION:-true}" != "false" ]; then
  if [ ! -d "SageAttention" ]; then
      echo "Starting SageAttention build in background (this takes time)..."
      (
        set -e
        git clone https://github.com/thu-ml/SageAttention.git || true
        cd SageAttention
        pip install . --no-build-isolation
        pip install --no-cache-dir triton
      ) &> /var/log/sage_build.log &
      BUILD_PID=$!
  else
      BUILD_PID=""
  fi
else
  BUILD_PID=""
fi

# ---------------------------------------------------------------------------
# DOWNLOAD FUNCTION
# ---------------------------------------------------------------------------
hf_get() {
  local repo="$1" rel="$2" dest="$3"
  local dest_dir; dest_dir="$(dirname "$dest")"
  local filename; filename="$(basename "$dest")"

  if [ -f "$dest" ]; then
    echo "Exists: $filename"
    return 0
  fi

  mkdir -p "$dest_dir"
  
  # Ensure HF Transfer is enabled
  export HF_HUB_ENABLE_HF_TRANSFER=1

  # Download using the native HF client
  echo "Downloading $filename..."
  hf download "$repo" --include "$rel" --revision main --local-dir "$dest_dir" >/dev/null 2>&1
  
  # Handle the nested structure hf download creates
  local src="$dest_dir/$rel"
  if [ "$src" != "$dest" ] && [ -f "$src" ]; then
      mv -f "$src" "$dest"
      # Cleanup empty directories left behind
      rmdir -p "$(dirname "$src")" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# PRESET: SAM3
# ---------------------------------------------------------------------------
if [ "${PRESET_SAM3:-false}" != "false" ]; then
  echo "Install Easy-Sam3..."
  ( cd /ComfyUI/custom_nodes/ && { [ -d "ComfyUI-Easy-Sam3" ] || git clone https://github.com/yolain/ComfyUI-Easy-Sam3; } && cd ComfyUI-Easy-Sam3 && pip install -r requirements.txt )

  # Download SAM3 Model using hf_get for consistency
  echo "Downloading SAM3 Model..."
  hf_get "yolain/sam3-safetensors" "sam3-fp16.safetensors" "/workspace/ComfyUI/models/sam3/sam3-fp16.safetensors"
  
  echo "SAM3 Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET: VIDEO UPSCALER
# ---------------------------------------------------------------------------
if [ "${PRESET_VIDEO_UPSCALER:-false}" != "false" ]; then
  echo "Preparing Video Upscaler Preset"
  
  # Downloads
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors" 
  
  hf_get "Kijai/WanVideo_comfy" "Wan22-Lightning/Wan2.2-Lightning_T2V-v1.1-A14B-4steps-lora_LOW_fp16.safetensors" "/workspace/ComfyUI/models/loras/Wan2.2-Lightning_T2V-v1.1-A14B-4steps-lora_LOW_fp16.safetensors" 
  hf_get "Phips/4xNomos8kDAT" "4xNomos8kDAT.safetensors" "/workspace/ComfyUI/models/upscale_models/4xNomos8kDAT.safetensors"
  hf_get "ai-forever/Real-ESRGAN" "RealESRGAN_x2.pth" "/workspace/ComfyUI/models/upscale_models/RealESRGAN_x2.pth"
  
  echo "Video Upscaler Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET: WAN 2.2 T2V
# ---------------------------------------------------------------------------
if [ "${PRESET_WAN_2_2_T2V:-false}" != "false" ]; then
  echo "Preparing Wan 2.2 T2V Preset"

  # Common Dependencies
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors" 
  
  # Diffusion Models (T2V)
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors"

  # LoRAs (T2V)
  hf_get "lightx2v/Wan2.2-Distill-Loras" "wan2.2_t2v_A14b_low_noise_lora_rank64_lightx2v_4step_1217.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_t2v_A14b_low_noise_lora_rank64_lightx2v_4step_1217.safetensors"
  hf_get "lightx2v/Wan2.2-Distill-Loras" "wan2.2_t2v_A14b_high_noise_lora_rank64_lightx2v_4step_1217.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_t2v_A14b_high_noise_lora_rank64_lightx2v_4step_1217.safetensors"
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"

  echo "Wan 2.2 T2V Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET: WAN 2.2 I2V
# ---------------------------------------------------------------------------
if [ "${PRESET_WAN_2_2_I2V:-false}" != "false" ]; then
  echo "Preparing Wan 2.2 I2V Preset"

  # Common Dependencies
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors" 
  
  # Diffusion Models (I2V)
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" 

  # LoRAs (I2V)
  hf_get "lightx2v/Wan2.2-Distill-Loras" "wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"
  hf_get "lightx2v/Wan2.2-Distill-Loras" "wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors"
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" "/workspace/ComfyUI/models/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" 

  echo "Wan 2.2 I2V Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET: WAN 2.1 VACE
# ---------------------------------------------------------------------------
if [ "${PRESET_WAN_2_1_VACE:-false}" != "false" ]; then
  echo "Preparing Wan 2.1 VACE Preset"

  # Common Dependencies
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors" 
  hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors" 

  # VACE Model (Note: Repo is 2.1 repackaged, not 2.2)
  hf_get "Comfy-Org/Wan_2.1_ComfyUI_repackaged" "split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors" "/workspace/ComfyUI/models/diffusion_models/wan2.1_vace_14B_fp16.safetensors"

  # VACE LoRA
  hf_get "Kijai/WanVideo_comfy" "Wan21_CausVid_14B_T2V_lora_rank32.safetensors" "/workspace/ComfyUI/models/loras/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"

  echo "Wan 2.1 VACE Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET: Z-IMAGE TURBO
# ---------------------------------------------------------------------------
if [ "${PRESET_ZIMAGE_TURBO:-false}" != "false" ]; then
  echo "Preparing Z-Image Turbo Preset"

  hf_get "Comfy-Org/z_image_turbo" "split_files/diffusion_models/z_image_turbo_bf16.safetensors" "/workspace/ComfyUI/models/diffusion_models/z_image_turbo_bf16.safetensors" 
  hf_get "Comfy-Org/z_image_turbo" "split_files/text_encoders/qwen_3_4b.safetensors" "/workspace/ComfyUI/models/clip/qwen_3_4b.safetensors" 
  hf_get "Comfy-Org/z_image_turbo" "split_files/vae/ae.safetensors" "/workspace/ComfyUI/models/vae/ae.safetensors" 
  
  hf_get "Phips/4xNomos8kDAT" "4xNomos8kDAT.safetensors" "/workspace/ComfyUI/models/upscale_models/4xNomos8kDAT.safetensors"
  hf_get "ai-forever/Real-ESRGAN" "RealESRGAN_x2.pth" "/workspace/ComfyUI/models/upscale_models/RealESRGAN_x2.pth"

  echo "Z-Image Turbo Preset: Complete."
fi

# ---------------------------------------------------------------------------
# Nunchaku
# ---------------------------------------------------------------------------
if [ "${NUNCHAKU:-true}" != "false" ]; then
  echo "Installing Nunchaku..."
  (
    set -e
    cd /ComfyUI/custom_nodes
    [ ! -d "ComfyUI-nunchaku" ] && git clone https://github.com/nunchaku-tech/ComfyUI-nunchaku/ || (cd ComfyUI-nunchaku && git pull)
    
    TORCH_VERSION=$(python -c "import torch; print(torch.__version__.split('+')[0][:3])")
    check_url() { curl --head --silent --fail "$1" > /dev/null 2>&1; }
    
    WHEEL_BASE="https://github.com/nunchaku-tech/nunchaku/releases/download/v1.1.0"
    WHEEL_URL="${WHEEL_BASE}/nunchaku-1.1.0+torch${TORCH_VERSION}-cp312-cp312-linux_x86_64.whl"
    
    if check_url "${WHEEL_URL}"; then
      pip install "${WHEEL_URL}"
    else
      for VER in 2.8 2.7 2.6 2.5 2.4 2.3; do
        FB_URL="${WHEEL_BASE}/nunchaku-1.0.0+torch${VER}-cp312-cp312-linux_x86_64.whl"
        if check_url "${FB_URL}"; then pip install "${FB_URL}"; break; fi
      done
    fi
  )
fi

# ---------------------------------------------------------------------------
# WAIT FOR SAGEATTENTION BUILD TO FINISH
# ---------------------------------------------------------------------------
if [ -n "${BUILD_PID:-}" ]; then
  if kill -0 "$BUILD_PID" 2>/dev/null; then
      echo "----------------------------------------------------------------"
      echo "Waiting for SageAttention build to finish..."
      echo "You can monitor progress with: tail -f /var/log/sage_build.log"
      echo "----------------------------------------------------------------"
      # This tails the log until the PID (SageAttention build) finishes
      tail -f /var/log/sage_build.log --pid=$BUILD_PID
  fi
fi

# ---------------------------------------------------------------------------
# RUNTIME ENV FIXES
# ---------------------------------------------------------------------------
# Force timm back to 0.9.16 to fix LayerStyle_Advance
pip install "timm==0.9.16" > /dev/null 2>&1
# FORCE reinstall onnxruntime-gpu 
pip install --force-reinstall onnxruntime-gpu --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/ > /dev/null 2>&1

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
if ! pgrep -f "main.py --listen" > /dev/null; then
  echo "Launching ComfyUI"
  ARGS="--listen --enable-cors-header --preview-method auto"
  [ "${SAGE_ATTENTION:-true}" != "false" ] && ARGS="$ARGS --use-sage-attention"
  nohup python3 "$COMFYUI_DIR/main.py" $ARGS > "/comfyui_${RUNPOD_POD_ID:-local}_nohup.log" 2>&1 &
fi

echo "ComfyUI is ready"
sleep infinity
