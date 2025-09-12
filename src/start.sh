#!/usr/bin/env bash
set -euo pipefail

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1 || true)"
export LD_PRELOAD="${TCMALLOC:-}"

# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "/workspace/additional_params.sh" ]; then
    chmod +x /workspace/additional_params.sh
    echo "Executing additional_params.sh..."
    /workspace/additional_params.sh
else
    echo "additional_params.sh not found in /workspace. Skipping..."
fi

if ! which aria2c > /dev/null 2>&1; then
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
[ -z "\$PS1" ] && return
PS1='\u@\h:\w\# '
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi
EOF
    echo ".bashrc created for root."
fi

# Install bash-completion if not present
if ! dpkg -s bash-completion > /dev/null 2>&1; then
    echo "Installing bash-completion..."
    apt-get update && apt-get install -y bash-completion
fi

echo "Starting JupyterLab on root directory..."
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser \
    --NotebookApp.token='' --NotebookApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
    --notebook-dir=/ &

# Create required model directories
echo "Creating model directories..."
for d in checkpoints clip vae controlnet diffusion_models unet loras clip_vision upscale_models; do
    mkdir -p "/workspace/ComfyUI/models/$d"
done

# Only build SageAttention if enabled
if [ "${SAGE_ATTENTION:-true}" != "false" ]; then
    echo "Building SageAttention in the background"
    (
      git clone https://github.com/thu-ml/SageAttention.git || true
      cd SageAttention || exit 1
      python3 setup.py install
      cd /
      pip install --no-cache-dir triton
    ) &> /var/log/sage_build.log &
    BUILD_PID=$!
else
    echo "sage_attention disabled, skipping SageAttention build"
    BUILD_PID=""
fi

# Function: Download multiple Hugging Face URLs in parallel with aria2c
download_hf_models() {
    local target_dir="$1"
    shift
    mkdir -p "$target_dir"

    local url_file
    url_file=$(mktemp)

    for url in "$@"; do
        local fname
        fname=$(basename "$url")
        local dest="$target_dir/$fname"
        if [[ -f "$dest" ]]; then
            echo "✔ Skipping $fname (already exists in $target_dir)"
        else
            echo "$url" >> "$url_file"
        fi
    done

    if [[ -s "$url_file" ]]; then
        echo "⬇ Starting parallel downloads into $target_dir"
        aria2c -d "$target_dir" -i "$url_file" \
               -x 16 -s 16 -j 4 --continue=true --summary-interval=5
    else
        echo "All requested models already present in $target_dir"
    fi

    rm -f "$url_file"
}

# Only prepare Video Upscaler Preset if enabled
if [ "${PRESET_VIDEO_UPSCALER:-true}" != "false" ]; then
    echo "Preparing Video Upscaler Preset"
    cd /ComfyUI/custom_nodes/
    git clone https://github.com/ClownsharkBatwing/RES4LYF/ || true
    cd RES4LYF || exit 1
    pip install -r requirements.txt

    # Batch download models
    download_hf_models "/workspace/ComfyUI/models/diffusion_models" \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

    download_hf_models "/workspace/ComfyUI/models/clip" \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors"

    download_hf_models "/workspace/ComfyUI/models/vae" \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"

    download_hf_models "/workspace/ComfyUI/models/loras" \
      "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors"

    download_hf_models "/workspace/ComfyUI/models/upscale_models" \
      "https://huggingface.co/Phips/4xNomos8kDAT/resolve/main/4xNomos8kDAT.safetensors"

    # Rename LoRA if needed
    if [ -f "/workspace/ComfyUI/models/loras/low_noise_model.safetensors" ]; then
        mv /workspace/ComfyUI/models/loras/low_noise_model.safetensors \
           /workspace/ComfyUI/models/loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors
        echo "LoRA renamed successfully"
    fi
    echo "Video Upscaler setup completed"
else
    echo "PRESET_VIDEO_UPSCALER disabled, skipping Video Upscaler setup"
fi

# Copy workflows from ComfyUI-Distributed-Pod
mkdir -p "$WORKFLOW_DIR"
SOURCE_WORKFLOW_DIR="/ComfyUI-Distributed-Pod/workflows"
if [ -d "$SOURCE_WORKFLOW_DIR" ]; then
    cp -r "$SOURCE_WORKFLOW_DIR/"* "$WORKFLOW_DIR/" || true
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
    cat <<EOL > "$COMFYUI_DIR/extra_model_paths.yaml"
comfyui:
  base_path: /workspace/ComfyUI
  is_default: true
  checkpoints: models/checkpoints/
  clip: models/clip/
  clip_vision: models/clip_vision/
  controlnet: models/controlnet/
  diffusion_models: models/diffusion_models/
  embeddings: models/embeddings/
  florence2: models/florence2/
  ipadapter: models/ipadapter/
  loras: models/loras/
  style_models: models/style_models/
  text_encoders: models/text_encoders/
  unet: models/unet/
  upscale_models: models/upscale_models/
  vae: models/vae/
EOL
fi

# Update ComfyUI + custom nodes
cd /ComfyUI/
git pull
pip install -r requirements.txt
cd /ComfyUI/custom_nodes/ComfyUI-Distributed/ && git pull
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/ && git pull
cd /ComfyUI/custom_nodes/ComfyUI-KJNodes/ && git pull

# Wait for SageAttention build if running
if [ -n "${BUILD_PID}" ]; then
    echo "Waiting for SageAttention build..."
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        sleep 10
        echo "SageAttention build still in progress..."
    done
    echo "SageAttention build complete"
fi

# Start ComfyUI
echo "Launching ComfyUI"
if [ "${SAGE_ATTENTION:-true}" = "false" ]; then
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header \
        > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
else
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header --use-sage-attention \
        > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
fi

until curl --silent --fail "$URL" --output /dev/null; do
  echo "Waiting for ComfyUI..."
  sleep 2
done

echo "✅ ComfyUI is ready"
sleep infinity
