#!/usr/bin/env bash

# Environment Variables (optional):
# - HF_API_TOKEN: Your HuggingFace API token for authenticated downloads
# - PARALLEL_DOWNLOADS: Set to 'true' for parallel downloads (faster but less progress visibility)
# - CLEAR_HF_CACHE: Set to 'true' to clear HF cache after downloads to save disk space
# - SAGE_ATTENTION: Set to 'false' to disable SageAttention
# - PRESET_VIDEO_UPSCALER: Set to 'false' to skip Video Upscaler preset

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

# Install aria2 if needed (still useful for non-HF downloads)
if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

# Install curl if needed
if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# ===== NEW: Install HuggingFace CLI and hf_transfer for blazing fast downloads =====
echo "Setting up HuggingFace fast download tools..."
if ! pip show huggingface-hub > /dev/null 2>&1; then
    echo "Installing HuggingFace CLI..."
    pip install -U "huggingface_hub[cli]"
else
    echo "HuggingFace CLI already installed"
fi

if ! pip show hf_transfer > /dev/null 2>&1; then
    echo "Installing hf_transfer for blazingly fast speeds..."
    pip install hf_transfer
else
    echo "hf_transfer already installed"
fi

# Enable HF Transfer for all HuggingFace downloads
export HF_HUB_ENABLE_HF_TRANSFER=1
echo "HF_TRANSFER enabled for maximum download speeds"

# Optional: Login to HuggingFace (comment out if not needed or using public models only)
# You can set HF_API_TOKEN environment variable instead of interactive login
if [ -n "$HF_API_TOKEN" ]; then
    echo "Logging into HuggingFace with provided token..."
    huggingface-cli login --token "$HF_API_TOKEN" --add-to-git-credential
elif [ -f ~/.cache/huggingface/token ]; then
    echo "HuggingFace token already exists"
else
    echo "No HF_API_TOKEN found. Continuing without login (public models only)..."
fi
# ===== END NEW SECTION =====

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
    echo "Preparing Video Upscaler Preset in the background"
    (
      cd /ComfyUI/custom_nodes/
      git clone https://github.com/ClownsharkBatwing/RES4LYF/
      cd RES4LYF || exit 1
      pip install -r requirements.txt
      
      # ===== UPDATED: Using HF Transfer for HuggingFace downloads =====
      echo "Starting parallel downloads of Video Upscaler models using HF Transfer..."
      
      # Function to download HF model with progress tracking
      download_hf_model() {
          local repo_id="$1"
          local filename="$2"
          local target_dir="$3"
          local output_name="${4:-$filename}"
          
          echo "Downloading $filename from $repo_id..."
          # Download to temp location first
          HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download "$repo_id" "$filename" \
              --local-dir-use-symlinks False \
              --local-dir "/tmp/hf_downloads"
          
          # Move to target location with proper name
          mkdir -p "$target_dir"
          mv "/tmp/hf_downloads/$filename" "$target_dir/$output_name"
          echo "Downloaded $output_name to $target_dir"
      }
      
      # Download all models in parallel using background processes
      download_hf_model "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
          "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
          "/workspace/ComfyUI/models/diffusion_models" \
          "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" &
      
      download_hf_model "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
          "split_files/text_encoders/umt5_xxl_fp16.safetensors" \
          "/workspace/ComfyUI/models/clip" \
          "umt5_xxl_fp16.safetensors" &
      
      download_hf_model "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
          "split_files/vae/wan_2.1_vae.safetensors" \
          "/workspace/ComfyUI/models/vae" \
          "wan_2.1_vae.safetensors" &
      
      download_hf_model "lightx2v/Wan2.2-Lightning" \
          "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" \
          "/workspace/ComfyUI/models/loras" \
          "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1_low_noise_model.safetensors" &
      
      download_hf_model "Phips/4xNomos8kDAT" \
          "4xNomos8kDAT.safetensors" \
          "/workspace/ComfyUI/models/upscale_models" \
          "4xNomos8kDAT.safetensors" &
      
      # Wait for all background downloads to complete
      wait
      echo "All Video Upscaler models downloaded successfully"
      
      # Clean up temp directory
      rm -rf /tmp/hf_downloads
      
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

# Simplified monitoring for HF downloads
if [ -n "$VIDEO_UPSCALER_PID" ]; then
    echo "Waiting for Video Upscaler downloads to complete..."
    while kill -0 "$VIDEO_UPSCALER_PID" 2>/dev/null; do
        echo "Video Upscaler setup in progress..."
        sleep 10
    done
    echo "Video Upscaler setup complete"
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
