#!/usr/bin/env bash

# --- Speedy HF downloads: install and enable hf_transfer ---------------------
# (Done early so any HF downloads benefit.)
pip install -U "huggingface_hub[cli]" hf_transfer >/dev/null 2>&1 || true
export HF_HUB_ENABLE_HF_TRANSFER=1
# Optional: keep cache in a predictable place
export HF_HOME=/workspace/.cache/huggingface
mkdir -p "${HF_HOME}"

# Login non-interactively if token provided
if [ -n "${HF_API_TOKEN:-}" ]; then
  huggingface-cli login --token "$HF_API_TOKEN" --add-to-git-credential >/dev/null 2>&1 || true
fi
# ------------------------------------------------------------------------------

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "/workspace/additional_params.sh" ]; then
    chmod +x /workspace/additional_params.sh
    echo "Executing additional_params.sh..."
    /workspace/additional_params.sh
else
    echo "additional_params.sh not found in /workspace. Skipping..."
fi

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

# Create required model directories if they don't exist
echo "Creating model directories..."
mkdir -p /workspace/ComfyUI/models/checkpoints/
mkdir -p /workspace/ComfyUI/models/clip/
mkdir -p /workspace/ComfyUI/models/vae/
mkdir -p /workspace/ComfyUI/models/controlnet/
mkdir -p /workspace/ComfyUI/models/diffusion_models/
mkdir -p /workspace/ComfyUI/models/unet/
mkdir -p /workspace/ComfyUI/models/loras/
mkdir -p /workspace/ComfyUI/models/clip_vision/
mkdir -p /workspace/ComfyUI/models/upscale_models/
mkdir -p /workspace/ComfyUI/models/text_encoders/

# ---------- Helpers for fast HF downloads with fallback to aria2 -------------
# Parse a huggingface.co "resolve" URL into REPO and INCLUDE path.
_parse_hf_url() {
  # $1 = full URL
  # outputs: "repo_id include_path"
  local url="$1"
  local repo include
  repo="$(echo "$url" | sed -E 's#https?://huggingface\.co/([^/]+/[^/]+)/.*#\1#')"
  include="$(echo "$url" | sed -E 's#https?://huggingface\.co/[^/]+/[^/]+/resolve/[^/]+/(.*)#\1#')"
  echo "$repo" "$include"
}

# Try to download a single HF file using hf_transfer (via huggingface-cli).
_hf_transfer_download() {
  # $1=url  $2=dest_dir  $3=dest_name (optional)
  local url="$1" dest_dir="$2" dest_name="$3"
  if ! command -v huggingface-cli >/dev/null 2>&1; then
    return 1
  fi
  read -r repo include <<< "$(_parse_hf_url "$url")"
  if [ -z "$repo" ] || [ -z "$include" ]; then
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  # Use hf_transfer by setting env var; avoid symlinks so we can move files cleanly
  HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download "$repo" \
    --include "$include" \
    --revision main \
    --repo-type model \
    --local-dir "$tmpdir" \
    --local-dir-use-symlinks False >/dev/null 2>&1

  local src="$tmpdir/$include"
  if [ -f "$src" ]; then
    mkdir -p "$dest_dir"
    if [ -n "$dest_name" ]; then
      mv -f "$src" "$dest_dir/$dest_name"
    else
      mv -f "$src" "$dest_dir/"
    fi
    rm -rf "$tmpdir"
    echo "Downloaded via hf_transfer: $repo :: $include -> $dest_dir/${dest_name:-$(basename "$src")}"
    return 0
  else
    rm -rf "$tmpdir"
    return 1
  fi
}

# Unified downloader: prefer hf_transfer; fallback to aria2c
fast_get() {
  # $1=url  $2=dest_dir  $3=dest_name (optional)
  local url="$1" dest_dir="$2" dest_name="$3"

  if _hf_transfer_download "$url" "$dest_dir" "$dest_name"; then
    return 0
  fi

  echo "hf_transfer unavailable/failed for $url — falling back to aria2c"
  mkdir -p "$dest_dir"
  aria2c -x 16 -s 16 -j 4 -d "$dest_dir" ${dest_name:+-o "$dest_name"} "$url"
}
# ------------------------------------------------------------------------------

# Only build SageAttention if sage_attention are enabled
if [ "$SAGE_ATTENTION" != "false" ]; then
    echo "Building SageAttention in the background"
    (
      git clone https://github.com/thu-ml/SageAttention.git
      cd SageAttention || exit 1
      python3 setup.py install
      cd /
      pip install --no-cache-dir triton
    ) &> /var/log/sage_build.log &      # run in background, log output

    BUILD_PID=$!
    echo "Background build started (PID: $BUILD_PID)"
else
    echo "sage_attention disabled, skipping SageAttention build"
    BUILD_PID=""
fi

# Only prepare Video Upscaler Preset if enabled
if [ "$PRESET_VIDEO_UPSCALER" != "false" ]; then
    echo "Preparing Video Upscaler Preset in the background"
    (
      cd /ComfyUI/custom_nodes/
      git clone https://github.com/ClownsharkBatwing/RES4LYF/ || true
      cd RES4LYF || exit 1
      pip install -r requirements.txt

      echo "Starting fast HF downloads for Video Upscaler models..."
      # 1) Diffusion model
      fast_get "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
               "/workspace/ComfyUI/models/diffusion_models" "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

      # 2) Text encoder (goes under text_encoders in your mapping; original path said clip)
      fast_get "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors" \
               "/workspace/ComfyUI/models/text_encoders" "umt5_xxl_fp16.safetensors"

      # 3) VAE
      fast_get "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
               "/workspace/ComfyUI/models/vae" "wan_2.1_vae.safetensors"

      # 4) LoRA
      fast_get "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" \
               "/workspace/ComfyUI/models/loras" "low_noise_model.safetensors"

      # 5) Upscaler
      fast_get "https://huggingface.co/Phips/4xNomos8kDAT/resolve/main/4xNomos8kDAT.safetensors" \
               "/workspace/ComfyUI/models/upscale_models" "4xNomos8kDAT.safetensors"

      # Rename LoRA
      if [ -f "/workspace/ComfyUI/models/loras/low_noise_model.safetensors" ]; then
        mv /workspace/ComfyUI/models/loras/low_noise_model.safetensors \
           /workspace/ComfyUI/models/loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors
        echo "LoRA renamed successfully"
      fi

      echo "Video Upscaler setup completed"
    ) &> /var/log/video_upscaler_setup.log &

    VIDEO_UPSCALER_PID=$!
    echo "Video Upscaler setup started in background (PID: $VIDEO_UPSCALER_PID)"
else
    echo "PRESET_VIDEO_UPSCALER disabled, skipping Video Upscaler setup"
    VIDEO_UPSCALER_PID=""
fi

# Copy workflows from ComfyUI-Distributed-Pod
mkdir -p "$WORKFLOW_DIR"
SOURCE_WORKFLOW_DIR="/ComfyUI-Distributed-Pod/workflows"
if [ -d "$SOURCE_WORKFLOW_DIR" ]; then
    cp -r "$SOURCE_WORKFLOW_DIR/"* "$WORKFLOW_DIR/"
    echo "Workflows copied successfully."
else
    echo "Workflow source directory not found: $SOURCE_WORKFLOW_DIR"
fi

# Copy extra_model_paths.yaml
SOURCE_YAML="/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml"
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

# Update ComfyUI
cd /ComfyUI/
git pull
pip install -r /ComfyUI/requirements.txt

# (Re)ensure fast HF bits remain installed even if requirements touched versions
python3 -m pip install -U "huggingface_hub[cli]" hf_transfer >/dev/null 2>&1 || true
export HF_HUB_ENABLE_HF_TRANSFER=1

# Update ComfyUI-Distributed
echo "Updating ComfyUI-Distributed."
cd /ComfyUI/custom_nodes/ComfyUI-Distributed/
git pull

# Update WanVideoWrapper
echo "Updating WanVideoWrapper."
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/
git pull

# Update KJNodes
echo "Updating KJNodes."
cd /ComfyUI/custom_nodes/ComfyUI-KJNodes/
git pull

# Function to monitor download progress (kept for the background tasks)
monitor_download_progress() {
    local pid=$1
    local name=$2
    local log_file=$3
    local last_progress=""

    while kill -0 "$pid" 2>/dev/null; do
        if [ -f "$log_file" ]; then
            current_progress=$(grep -E "(\[[#\.]+\]|Download complete:|ERROR|SEED)" "$log_file" | tail -1)
            if [ "$current_progress" != "$last_progress" ] && [ -n "$current_progress" ]; then
                echo "$name: $current_progress"
                last_progress="$current_progress"
            fi
        fi
        sleep 5
    done

    if [ -f "$log_file" ]; then
        if grep -q "ERROR" "$log_file"; then
            echo "$name: Completed with errors. Check $log_file for details."
        else
            echo "$name: Complete"
        fi
    fi
}

if [ -n "$VIDEO_UPSCALER_PID" ]; then
    echo "Waiting for Video Upscaler downloads to complete..."
    monitor_download_progress "$VIDEO_UPSCALER_PID" "Video Upscaler" "/var/log/video_upscaler_setup.log"
fi

if [ -n "$BUILD_PID" ]; then
    echo "Waiting for SageAttention build to complete..."
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        echo "SageAttention build in progress... (this can take up to 5 minutes)"
        sleep 10
    done
    echo "SageAttention build complete"
fi

# Start ComfyUI
echo "Launching ComfyUI"
if [ "$SAGE_ATTENTION" = "false" ]; then
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
else
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header --use-sage-attention > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
fi

until curl --silent --fail "$URL" --output /dev/null; do
  echo "Launching ComfyUI"
  sleep 2
done
echo "ComfyUI is ready"
sleep infinity
