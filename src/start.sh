#!/usr/bin/env bash
set -euo pipefail

echo "Speedy HF downloads: install + enable hf_transfer"
# Install hub client + CLI with the hf_transfer extra (pulls the Rust helper)
python3 -m pip install -U "huggingface_hub[cli,hf_transfer]" hf_transfer >/dev/null 2>&1 || true

# Enable hf_transfer and make sure the client doesn't route via XET (which bypasses hf_transfer)
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HUB_DISABLE_XET=1
export HF_DEBUG=1                     # verbose hub logs so you can SEE what's happening
export HF_HOME=/workspace/.cache/huggingface
mkdir -p "${HF_HOME}"

# Optional non-interactive login if you set HF_API_TOKEN in the environment
if command -v huggingface-cli >/dev/null 2>&1 && [ -n "${HF_API_TOKEN:-}" ]; then
  echo "Logging into Hugging Face with token from HF_API_TOKEN"
  huggingface-cli login --token "$HF_API_TOKEN" --add-to-git-credential >/dev/null 2>&1 || true
fi

# Self-check: print whether hf_transfer is both available and enabled
python3 - <<'PY'
import os, importlib.util
from huggingface_hub.file_download import _hf_transfer
print(f"[hf_transfer] hub: available={_hf_transfer.is_available()} enabled={_hf_transfer.is_enabled()} "
      f"(HF_HUB_ENABLE_HF_TRANSFER={os.getenv('HF_HUB_ENABLE_HF_TRANSFER')}, HF_HUB_DISABLE_XET={os.getenv('HF_HUB_DISABLE_XET')})")
print(f"[hf_transfer] module present? {importlib.util.find_spec('hf_transfer') is not None}")
PY

# -----------------------------------------------------------------------------
# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1 || true)"
export LD_PRELOAD="${TCMALLOC:-}"

# Any pre-start overrides
if [ -f "/workspace/additional_params.sh" ]; then
  chmod +x /workspace/additional_params.sh
  echo "Executing additional_params.sh..."
  /workspace/additional_params.sh
else
  echo "additional_params.sh not found in /workspace. Skipping..."
fi

# System deps used elsewhere in the script
if ! command -v aria2c >/dev/null 2>&1; then
  echo "Installing aria2..."
  apt-get update && apt-get install -y aria2
else
  echo "aria2 is already installed"
fi

if ! command -v curl >/dev/null 2>&1; then
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
  cat <<'EOF' > /root/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.
[ -z "$PS1" ] && return
PS1='\u@\h:\w\# '
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
  . /etc/bash_completion
fi
EOF
  echo ".bashrc created for root."
fi

# Install bash-completion if not present
if ! dpkg -s bash-completion >/dev/null 2>&1; then
  echo "Installing bash-completion..."
  apt-get update && apt-get install -y bash-completion
fi

echo "Starting JupyterLab on root directory..."
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser \
  --NotebookApp.token='' --NotebookApp.password='' \
  --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
  --notebook-dir=/ &

# Create required model directories if they don't exist
echo "Creating model directories..."
mkdir -p /workspace/ComfyUI/models/{checkpoints,clip,vae,controlnet,diffusion_models,unet,loras,clip_vision,upscale_models,text_encoders}

# ---------- Helpers for fast HF downloads (Hub -> hf_transfer) w/ aria2 fallback ----------
# Bash wrapper that uses Python hub (fast path) then falls back to aria2c if needed.
hf_get () {  # repo_id path_in_repo dest_path
  local repo="$1"; local file="$2"; local dest="$3"
  local dest_dir dest_name
  dest_dir="$(dirname "$dest")"
  dest_name="$(basename "$dest")"

  echo "[HF] ${repo} :: ${file}  ->  ${dest}"
  set +e
  python3 - <<PY
import os, time, shutil, sys
from huggingface_hub import hf_hub_download
repo = "${repo}"
file = "${file}"
dest = "${dest}"
t0 = time.time()
try:
    path = hf_hub_download(repo_id=repo, filename=file)  # uses hf_transfer when enabled
    dt = time.time() - t0
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy2(path, dest)
    size = os.path.getsize(dest)
    rate = (size/1e6)/dt if dt>0 else 0
    print(f"[HF] ok size={size/1e6:.2f}MB time={dt:.2f}s avg={rate:.1f}MB/s")
    sys.exit(0)
except Exception as e:
    print(f"[HF] hub failed: {e!r}")
    sys.exit(99)
PY
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    # Fallback to direct CDN with aria2c
    local cdn="https://huggingface.co/${repo}/resolve/main/${file}"
    echo "[HF->aria2] Fallback: ${cdn}"
    mkdir -p "$dest_dir"
    aria2c -x 16 -s 16 -j 4 -d "$dest_dir" -o "$dest_name" "$cdn"
  fi
}

# ------------------------------------------------------------------------------------------

# Only build SageAttention if enabled
if [ "${SAGE_ATTENTION:-}" != "false" ]; then
  echo "Building SageAttention in the background"
  (
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention || exit 1
    python3 setup.py install
    cd /
    python3 -m pip install --no-cache-dir triton
  ) &> /var/log/sage_build.log &
  BUILD_PID=$!
  echo "Background build started (PID: $BUILD_PID)"
else
  echo "sage_attention disabled, skipping SageAttention build"
  BUILD_PID=""
fi

# Only prepare Video Upscaler Preset if enabled
if [ "${PRESET_VIDEO_UPSCALER:-}" != "false" ]; then
  echo "Preparing Video Upscaler Preset (hf_transfer path) in the background"
  (
    cd /ComfyUI/custom_nodes/
    git clone https://github.com/ClownsharkBatwing/RES4LYF/ || true
    cd RES4LYF || exit 1
    python3 -m pip install -r requirements.txt

    # ---- These five downloads now go through the Hub (accelerated by hf_transfer) ----
    hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
           "/workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

    # Keep destination under clip (matches your original layout; change to text_encoders/ if you prefer)
    hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" \
           "/workspace/ComfyUI/models/clip/umt5_xxl_fp16.safetensors"

    hf_get "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/vae/wan_2.1_vae.safetensors" \
           "/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors"

    # Save directly with the final name so no rename step is needed
    hf_get "lightx2v/Wan2.2-Lightning" "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" \
           "/workspace/ComfyUI/models/loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors"

    hf_get "Phips/4xNomos8kDAT" "4xNomos8kDAT.safetensors" \
           "/workspace/ComfyUI/models/upscale_models/4xNomos8kDAT.safetensors"

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
  cat <<'EOL' > "$COMFYUI_DIR/extra_model_paths.yaml"
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

# Update ComfyUI & ensure our hub bits remain
cd /ComfyUI/
git pull
python3 -m pip install -r /ComfyUI/requirements.txt
python3 -m pip install -U "huggingface_hub[cli,hf_transfer]" hf_transfer >/dev/null 2>&1 || true
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HUB_DISABLE_XET=1
export HF_DEBUG=1

# Update custom nodes
echo "Updating ComfyUI-Distributed."
cd /ComfyUI/custom_nodes/ComfyUI-Distributed/ && git pull

echo "Updating WanVideoWrapper."
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/ && git pull

echo "Updating KJNodes."
cd /ComfyUI/custom_nodes/ComfyUI-KJNodes/ && git pull

# Monitor background tasks
monitor_download_progress() {
  local pid=$1 name=$2 log_file=$3 last=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ -f "$log_file" ]; then
      cur=$(grep -E "(HF]|ok size=|aria2|Download complete:|ERROR|SEED)" "$log_file" | tail -1 || true)
      if [ "$cur" != "$last" ] && [ -n "$cur" ]; then
        echo "$name: $cur"
        last="$cur"
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

if [ -n "${VIDEO_UPSCALER_PID:-}" ]; then
  echo "Waiting for Video Upscaler downloads to complete..."
  monitor_download_progress "$VIDEO_UPSCALER_PID" "Video Upscaler" "/var/log/video_upscaler_setup.log"
fi

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
if [ "${SAGE_ATTENTION:-}" = "false" ]; then
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
