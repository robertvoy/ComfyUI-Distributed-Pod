#!/usr/bin/env bash

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

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# Enable Hugging Face hf_transfer for faster downloads via huggingface_hub
export HF_HUB_ENABLE_HF_TRANSFER=1
if ! python3 - 2>/dev/null <<'PY'
import importlib
import sys
import pkgutil
missing = []
for pkg in ("huggingface_hub", "hf_transfer"):
    if pkgutil.find_loader(pkg) is None:
        missing.append(pkg)
sys.exit(1 if missing else 0)
PY
then
    echo "Installing hf_transfer and huggingface_hub..."
    pip install --no-cache-dir -U hf_transfer huggingface_hub
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
    echo "Preparing Video Upscaler Preset with hf_transfer (via huggingface_hub)"
    (
      cd /ComfyUI/custom_nodes/ || exit 1
      if [ ! -d "RES4LYF" ]; then
        git clone https://github.com/ClownsharkBatwing/RES4LYF/
      fi
      cd RES4LYF || exit 1
      if [ -f requirements.txt ]; then
        pip install -r requirements.txt
      fi

      echo "Downloading Video Upscaler models using huggingface_hub (accelerated by hf_transfer)..."
      python3 - <<'PY'
import os, shutil
from huggingface_hub import hf_hub_download

os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"

def fetch(repo_id, filename, dest_dir, out_name=None):
    os.makedirs(dest_dir, exist_ok=True)
    path = hf_hub_download(repo_id=repo_id, filename=filename, local_dir=dest_dir, local_dir_use_symlinks=False)
    if out_name:
        dest = os.path.join(dest_dir, out_name)
        if os.path.abspath(path) != os.path.abspath(dest):
            # Ensure the downloaded file sits directly in dest_dir (and rename if needed)
            shutil.move(path, dest)
    print(f"Downloaded: {filename} -> {dest_dir}")

fetch("Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors", "/workspace/ComfyUI/models/diffusion_models")
fetch("Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "split_files/text_encoders/umt5_xxl_fp16.safetensors", "/workspace/ComfyUI/models/clip")
fetch("Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "split_files/vae/wan_2.1_vae.safetensors", "/workspace/ComfyUI/models/vae")
fetch("lightx2v/Wan2.2-Lightning", "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors", "/workspace/ComfyUI/models/loras", out_name="Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors")
fetch("Phips/4xNomos8kDAT", "4xNomos8kDAT.safetensors", "/workspace/ComfyUI/models/upscale_models")
PY

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

# Wait for Video Upscaler downloads to complete (logs are in /var/log/video_upscaler_setup.log)
if [ -n "$VIDEO_UPSCALER_PID" ]; then
    echo "Waiting for Video Upscaler downloads to complete..."
    wait "$VIDEO_UPSCALER_PID"
    echo "Video Upscaler downloads complete."
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
