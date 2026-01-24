#!/usr/bin/env bash
set -euo pipefail

if [ -f /usr/lib/x86_64-linux-gnu/libcuda.so.1 ] && [ ! -f /usr/lib/x86_64-linux-gnu/libcuda.so ]; then
    ln -s /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so
    echo "Created libcuda.so symlink for Triton."
fi

TCMALLOC="$(ldconfig -p | awk '/libtcmalloc\.so\.[0-9]+/ {print $NF; exit}')"
[ -n "${TCMALLOC:-}" ] && export LD_PRELOAD="$TCMALLOC"

python3 -m pip install -U hf_transfer

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
  echo "WARNING: extra_model_paths.yaml was expected but not found."
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
# UPDATE NODES
# ---------------------------------------------------------------------------

update_node "https://github.com/kijai/ComfyUI-KJNodes.git"
update_node "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"


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
  hf download "$repo" --include "$rel" --revision main --local-dir "$dest_dir"
  
  # Handle the nested structure hf download creates
  local src="$dest_dir/$rel"
  if [ "$src" != "$dest" ] && [ -f "$src" ]; then
      mv -f "$src" "$dest"
      # Cleanup empty directories left behind
      rmdir -p "$(dirname "$src")" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# PRESET: LTX2
# ---------------------------------------------------------------------------
if [ "${PRESET_LTX2:-false}" != "false" ]; then
  echo "Preparing LTX-2 Preset"

  # 2. Text Encoder (Gemma 3 12B)
  hf_get "Comfy-Org/ltx-2" "split_files/text_encoders/gemma_3_12B_it.safetensors" "/workspace/ComfyUI/models/clip/gemma_3_12B_it.safetensors"

  # 3. Main Diffusion Model (19B Dev)
  hf_get "Lightricks/LTX-2" "ltx-2-19b-dev.safetensors" "/workspace/ComfyUI/models/checkpoints/ltx-2-19b-dev.safetensors"

  # 4. Spatial Upscaler
  hf_get "Lightricks/LTX-2" "ltx-2-spatial-upscaler-x2-1.0.safetensors" "/workspace/ComfyUI/models/latent_upscale_models/ltx-2-spatial-upscaler-x2-1.0.safetensors"

  # 5. Distilled LoRA (384)
  hf_get "Lightricks/LTX-2" "ltx-2-19b-distilled-lora-384.safetensors" "/workspace/ComfyUI/models/loras/ltx-2-19b-distilled-lora-384.safetensors"

  echo "LTX-2 Preset: Complete."
fi

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
# PRESET: QWEN EDIT 2511
# ---------------------------------------------------------------------------
if [ "${PRESET_QWEN_EDIT_2511:-false}" != "false" ]; then
  echo "Preparing Qwen Edit 2511 Preset"

  # Diffusion Model
  hf_get "Comfy-Org/Qwen-Image-Edit_ComfyUI" "split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors" "/workspace/ComfyUI/models/diffusion_models/qwen_image_edit_2511_bf16.safetensors"

  # VAE
  hf_get "Comfy-Org/Qwen-Image_ComfyUI" "split_files/vae/qwen_image_vae.safetensors" "/workspace/ComfyUI/models/vae/qwen_image_vae.safetensors"

  # Text Encoder
  hf_get "Comfy-Org/Qwen-Image_ComfyUI" "split_files/text_encoders/qwen_2.5_vl_7b.safetensors" "/workspace/ComfyUI/models/clip/qwen_2.5_vl_7b.safetensors"

  # LoRAs
  hf_get "lightx2v/Qwen-Image-Edit-2511-Lightning" "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors" "/workspace/ComfyUI/models/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"

  # LoRA (Next Scene)
  hf_get "lovis93/next-scene-qwen-image-lora-2509" "next-scene_lora-v2-3000.safetensors" "/workspace/ComfyUI/models/loras/next-scene_lora-v2-3000.safetensors"

  # LoRA (Multiple Angles)
  hf_get "fal/Qwen-Image-Edit-2511-Multiple-Angles-LoRA" "qwen-image-edit-2511-multiple-angles-lora.safetensors" "/workspace/ComfyUI/models/loras/qwen-image-edit-2511-multiple-angles-lora.safetensors"

  echo "Qwen Edit 2511 Preset: Complete."
fi

# ---------------------------------------------------------------------------
# PRESET: FLUX.2 KLEIN 9b
# ---------------------------------------------------------------------------
if [ "${PRESET_FLUX_2_KLEIN_9B:-false}" != "false" ]; then
  echo "Preparing Flux.2 Klein Preset..."

  # Flux 2 VAE
  hf_get "Comfy-Org/flux2-klein-4B" "split_files/vae/flux2-vae.safetensors" "/workspace/ComfyUI/models/vae/flux2-vae.safetensors"

  # Qwen Text Encoder (From 9B Repo)
  hf_get "Comfy-Org/flux2-klein-9B" "split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors" "/workspace/ComfyUI/models/clip/qwen_3_8b_fp8mixed.safetensors"

  # Flux 2 Klein 9B Model
  hf_get "black-forest-labs/FLUX.2-klein-9B" "flux-2-klein-9b.safetensors" "/workspace/ComfyUI/models/diffusion_models/flux-2-klein-9b.safetensors"

  echo "Flux.2 Klein Preset: Complete."
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
# RUNTIME ENV FIXES
# ---------------------------------------------------------------------------
# Force timm back to 0.9.16 to fix LayerStyle_Advance
# pip install "timm==0.9.16"

# FORCE reinstall onnxruntime-gpu 
# pip install --force-reinstall onnxruntime-gpu --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
LOG_FILE="/comfyui_${RUNPOD_POD_ID:-local}.log"

if ! pgrep -f "main.py --listen" > /dev/null; then
  echo "Launching ComfyUI"
  ARGS="--listen --enable-cors-header --preview-method auto"
  nohup python3 "$COMFYUI_DIR/main.py" $ARGS > "$LOG_FILE" 2>&1 &
fi

echo "----------------------------------------------------------------"
echo "Streaming logs from: $LOG_FILE"
echo "----------------------------------------------------------------"

touch "$LOG_FILE"
tail -f "$LOG_FILE"