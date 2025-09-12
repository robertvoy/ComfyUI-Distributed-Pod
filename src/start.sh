#!/usr/bin/env bash
set -e  # Exit on any error

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC:-}"

# Execute additional_params.sh if present
if [ -f "/workspace/additional_params.sh" ]; then
    chmod +x /workspace/additional_params.sh
    echo "Executing additional_params.sh..."
    /workspace/additional_params.sh
else
    echo "additional_params.sh not found in /workspace. Skipping..."
fi

# Install dependencies (consolidate apt updates)
if ! which aria2 > /dev/null 2>&1 || ! which curl > /dev/null 2>&1; then
    echo "Installing aria2 and curl..."
    apt-get update && apt-get install -y aria2 curl
else
    echo "aria2 and curl are already installed"
fi

URL="http://127.0.0.1:8188"
COMFYUI_DIR="/ComfyUI"
WORKFLOW_DIR="/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="/ComfyUI/custom_nodes"
export SHELL=/bin/bash

# Create a basic .bashrc for root
if [ ! -f /root/.bashrc ]; then
    cat <<EOF > /root/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.
# If not running interactively, don't do anything
[ -z "\$PS1" ] && return

# Set a fancy prompt (non-color, unless we know we "want" color)
PS1='\u@\h:\w\# '

# Enable programmable completion features
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
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &

# Create required model directories
echo "Creating model directories..."
mkdir -p /ComfyUI/models/{checkpoints,clip,vae,controlnet,diffusion_models,unet,loras,clip_vision,upscale_models}

# Build SageAttention if enabled
BUILD_PID=""
if [ "${SAGE_ATTENTION:-false}" != "false" ]; then
    echo "Building SageAttention in the background"
    (
        git clone https://github.com/thu-ml/SageAttention.git
        cd SageAttention || exit 1
        python3 setup.py install
        cd /
        pip install --no-cache-dir triton
    ) &> /var/log/sage_build.log &
    BUILD_PID=$!
    echo "Background build started (PID: $BUILD_PID)"
else
    echo "sage_attention disabled, skipping SageAttention build"
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

# Copy or create extra_model_paths.yaml
SOURCE_YAML="/ComfyUI-Distributed-Pod/src/extra_model_paths.yaml"
if [ -f "$SOURCE_YAML" ]; then
    cp "$SOURCE_YAML" "$COMFYUI_DIR/extra_model_paths.yaml"
    echo "extra_model_paths.yaml copied successfully."
else
    echo "YAML source file not found: $SOURCE_YAML. Creating from template..."
    cat <<EOL > "$COMFYUI_DIR/extra_model_paths.yaml"
comfyui:
  base_path: /ComfyUI
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

# Update ComfyUI and custom nodes
cd /ComfyUI/
git pull
pip install -r /ComfyUI/requirements.txt

echo "Updating ComfyUI-Distributed."
cd /ComfyUI/custom_nodes/ComfyUI-Distributed/
git pull

echo "Updating ComfyUI-WanVideoWrapper."
cd /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/
git pull

echo "Updating ComfyUI-KJNodes."
cd /ComfyUI/custom_nodes/ComfyUI-KJNodes/
git pull

# Prepare Video Upscaler Preset if enabled
if [ "${PRESET_VIDEO_UPSCALER:-false}" != "false" ]; then
    echo "Preparing Video Upscaler Preset"

    # Clone RES4LYF
    cd /ComfyUI/custom_nodes/
    if [ ! -d "RES4LYF" ]; then
        git clone https://github.com/ClownsharkBatwing/RES4LYF/
    fi
    cd RES4LYF || exit 1
    pip install -r requirements.txt

    # Download UNet model with hf_transfer (progress via aria2c)
    echo "Starting UNet model download (hf_transfer enabled for progress monitoring)..."
    HF_HUB_ENABLE_HF_TRANSFER=1 hf download Comfy-Org/Wan_2.2_ComfyUI_Repackaged \
        --include "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
        --revision main \
        --local-dir /ComfyUI/models/unet
    if [ $? -eq 0 ]; then
        echo "UNet model downloaded successfully."
    else
        echo "UNet download failed."
        exit 1
    fi

    # Download LoRA with hf_transfer (progress via aria2c)
    echo "Starting LoRA download (hf_transfer enabled for progress monitoring)..."
    HF_HUB_ENABLE_HF_TRANSFER=1 hf download lightx2v/Wan2.2-Lightning \
        --include "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" \
        --revision main \
        --local-dir /ComfyUI/models/loras
    if [ $? -eq 0 ] && [ -f "/ComfyUI/models/loras/low_noise_model.safetensors" ]; then
        mv /ComfyUI/models/loras/low_noise_model.safetensors \
           /ComfyUI/models/loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors
        echo "LoRA downloaded and renamed successfully."
    else
        echo "LoRA download or rename failed."
        exit 1
    fi
fi

# Wait for SageAttention build if applicable
if [ -n "$BUILD_PID" ]; then
    echo "Waiting for SageAttention build to complete..."
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        echo "SageAttention build in progress... (this can take up to 5 minutes)"
        sleep 10
    done
    echo "SageAttention build complete."
fi

# Start ComfyUI
echo "Launching ComfyUI"
if [ "${SAGE_ATTENTION:-false}" = "false" ]; then
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
else
    nohup python3 "$COMFYUI_DIR/main.py" --listen --enable-cors-header --use-sage-attention > "/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
fi

# Wait for ComfyUI to be ready
until curl --silent --fail "$URL" --output /dev/null; do
    echo "Waiting for ComfyUI to launch..."
    sleep 2
done
echo "ComfyUI is ready at $URL"
sleep infinity
