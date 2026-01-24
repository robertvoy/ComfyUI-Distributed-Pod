# ==================================================================
# STAGE 1: BUILDER
# ==================================================================
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=24 \
    MAX_JOBS=24 \
    VIRTUAL_ENV="/opt/venv" \
    PATH="/opt/venv/bin:$PATH"

# 1. Install System Deps & Python 3.12 (via Deadsnakes PPA)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common wget gpg && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev \
        git build-essential gcc g++ ninja-build \
        libgl1 libglib2.0-0 && \
    wget -qO- https://astral.sh/uv/install.sh | sh && \
    cp /root/.local/bin/uv /usr/local/bin/uv

# 2. Set up Virtual Environment
RUN ln -sf /usr/bin/python3.12 /usr/bin/python && \
    uv venv /opt/venv --python 3.12 && \
    uv pip install pip

# 3. Install PyTorch
# We create a constraint file to LOCK these versions preventing downgrades
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install torch==2.9.1+cu128 torchvision==0.24.1+cu128 torchaudio==2.9.1+cu128 \
    --extra-index-url https://download.pytorch.org/whl/cu128 && \
    echo "torch==2.9.1+cu128" > /tmp/constraints.txt && \
    echo "torchvision==0.24.1+cu128" >> /tmp/constraints.txt && \
    echo "torchaudio==2.9.1+cu128" >> /tmp/constraints.txt && \
    uv pip install "iopath>=0.1.10" && \
    uv pip install packaging setuptools wheel pyyaml gdown triton comfy-cli \
    jupyterlab jupyterlab-lsp jupyter-server jupyter-server-terminals \
    ipykernel jupyterlab_code_formatter huggingface_hub[cli] hf_transfer
        
# ------------------------------------------------------------
# COMPILE SAGEATTENTION
# ------------------------------------------------------------
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 10.0+PTX"

RUN git clone https://github.com/thu-ml/SageAttention.git && \
    cd SageAttention && \
    uv pip install . --no-build-isolation --constraint /tmp/constraints.txt && \
    cd .. && rm -rf SageAttention

# ------------------------------------------------------------
# INSTALL FLASH ATTENTION 2 (Wheel for Torch 2.8)
# ------------------------------------------------------------
ARG FLASH_ATTN_WHEEL_URL="https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.6.8/flash_attn-2.8.3+cu128torch2.9-cp312-cp312-linux_x86_64.whl"

RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install "${FLASH_ATTN_WHEEL_URL}" --constraint /tmp/constraints.txt

# ------------------------------------------------------------
# INSTALL COMFYUI & NODES
# ------------------------------------------------------------
WORKDIR /ComfyUI

RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git . && \
    uv pip install -r requirements.txt --constraint /tmp/constraints.txt

# Install Custom Nodes
WORKDIR /ComfyUI/custom_nodes
RUN --mount=type=cache,target=/root/.cache/uv \
    echo "Cloning repositories in parallel..." && \
    ( \
      git clone --depth 1 https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git & \
      git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git & \
      git clone --depth 1 https://github.com/rgthree/rgthree-comfy.git & \
      git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git & \
      git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Inspire-Pack.git & \
      git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git & \
      git clone --depth 1 https://github.com/robertvoy/ComfyUI-Distributed.git & \
      git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux.git & \
      git clone --depth 1 https://github.com/cubiq/ComfyUI_essentials.git & \
      git clone --depth 1 https://github.com/chflame163/ComfyUI_LayerStyle.git & \
      git clone --depth 1 https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git & \
      git clone --depth 1 https://github.com/yolain/ComfyUI-Easy-Use.git & \
      git clone --depth 1 https://github.com/ClownsharkBatwing/RES4LYF.git & \
      git clone --depth 1 https://github.com/crystian/ComfyUI-Crystools & \
      git clone --depth 1 https://github.com/kijai/ComfyUI-Florence2 & \
      git clone --depth 1 https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git & \
      git clone --depth 1 https://github.com/shootthesound/comfyUI-LongLook.git & \
      wait \
    ) && \
    # -------------------------------------------------------------------
    # LOOP: Sanitize requirements and install
    # -------------------------------------------------------------------
    for repo_dir in */ ; do \
        if [ -f "$repo_dir/requirements.txt" ]; then \
            echo "Installing requirements for $repo_dir..." && \
            sed -i '/^torch[>=<]/d' "$repo_dir/requirements.txt" && \
            sed -i '/^torch$/d' "$repo_dir/requirements.txt" && \
            sed -i '/^torchvision/d' "$repo_dir/requirements.txt" && \
            sed -i '/^torchaudio/d' "$repo_dir/requirements.txt" && \
            sed -i '/^opencv-/d' "$repo_dir/requirements.txt" && \
            sed -i '/^numpy/d' "$repo_dir/requirements.txt" && \
            \
            uv pip install -r "$repo_dir/requirements.txt" \
            --constraint /tmp/constraints.txt \
            --extra-index-url https://download.pytorch.org/whl/cu128; \
        fi; \
        if [ -f "$repo_dir/install.py" ]; then \
            python "$repo_dir/install.py"; \
        fi; \
    done

# Fix for UltimateSDUpscale (needs recursive submodule but we shallow cloned it)
RUN cd ComfyUI_UltimateSDUpscale && \
    git submodule update --init --recursive

# ----------------------------------------------------------
# DEPENDENCY FIXES
# ----------------------------------------------------------
# Force remove headless/contrib conflicts and reinstall
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip uninstall opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless || true && \
    uv pip install --no-deps "opencv-contrib-python-headless>=4.11.0" "timm>=1.0.0" && \
    uv pip install "numpy<2" && \
    uv pip install blend_modes && \
    uv pip install --force-reinstall onnxruntime-gpu --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/

# ==================================================================
# STAGE 2: RUNTIME
# ==================================================================
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04 AS final

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    HF_HUB_ENABLE_HF_TRANSFER=1

# Install Runtime Dependencies (Python 3.12)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common wget && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev \
        ffmpeg libgl1 libglib2.0-0 git aria2 vim procps \
        ninja-build libsndfile1 gcc g++ nginx \
        bash-completion && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3.12 /usr/bin/python

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /ComfyUI /ComfyUI

WORKDIR /ComfyUI

COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

# Shell configuration (bash completion, history, etc.)
COPY src/bashrc /root/.bashrc
COPY src/inputrc /root/.inputrc
ENV SHELL=/bin/bash
SHELL ["/bin/bash", "-c"]

CMD ["/start_script.sh"]