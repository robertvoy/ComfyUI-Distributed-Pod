#!/usr/bin/env bash
set -euo pipefail

# Use libtcmalloc for better memory management (use full path)
TCMALLOC="$(ldconfig -p | awk '/libtcmalloc\.so\.[0-9]+/ {print $NF; exit}')"
if [ -n "${TCMALLOC:-}" ]; then
  export LD_PRELOAD="$TCMALLOC"
fi

python3 -m pip install -U "huggingface_hub[cli]" hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HUB_DISABLE_XET=1
# export HF_DEBUG=1   # uncomment for verbose hub logs
[ -n "${HF_API_TOKEN:-}" ] && hf login --token "$HF_API_TOKEN" --non-interactive || true

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



# Only prepare Video Upscaler Preset if enabled
if [ "${PRESET_VIDEO_UPSCALER:-true}" != "false" ]; then
  echo "Preparing Video Upscaler Preset"
  (
    cd /ComfyUI/custom_nodes/
    git clone https://github.com/ClownsharkBatwing/RES4LYF/ || true
    cd RES4LYF || exit 1
    pip install -r requirements.txt

    # WAN 2.2 diffusion model (accelerated by hf_transfer)
    t0=$(date +%s)
    hf download Comfy-Org/Wan_2.2_ComfyUI_Repackaged \
      --include "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
      --revision main \
      --local-dir /tmp/hf_out
    f="/tmp/hf_out/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
    sz=$(stat -c%s "$f"); dt=$(( $(date +%s) - t0 ))
    awk -v s="$sz" -v d="$dt" 'BEGIN{printf("WAN 2.2 model avg throughput: %.1f MB/s (%.2f GB in %ds)\n", s/1048576/d, s/1073741824, d)}'
    install -D "$f" /workspace/ComfyUI/models/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors
  )
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
