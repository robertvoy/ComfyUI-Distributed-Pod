FROM pytorch/pytorch:2.7.0-cuda12.8-cudnn9-devel AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# Check Python version first
RUN python --version

# Install system dependencies only
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ffmpeg ninja-build git aria2 git-lfs wget vim \
        libgl1 libglib2.0-0 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Core Python tooling (skip if you want to check what's already installed)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip setuptools wheel && \
    pip install packaging pyyaml gdown triton comfy-cli jupyterlab jupyterlab-lsp \
        jupyter-server jupyter-server-terminals \
        ipykernel jupyterlab_code_formatter

# ComfyUI install
RUN --mount=type=cache,target=/root/.cache/pip \
    /usr/bin/yes | comfy --workspace /ComfyUI install

FROM base AS final

# Install additional packages
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install opencv-python

# Install custom nodes with pip cache
RUN --mount=type=cache,target=/root/.cache/pip \
    for repo in \
    https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git \
    https://github.com/kijai/ComfyUI-KJNodes.git \
    https://github.com/rgthree/rgthree-comfy.git \
    https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
    https://github.com/robertvoy/ComfyUI-Distributed.git \
    https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
    https://github.com/Fannovel16/comfyui_controlnet_aux.git \
    https://github.com/cubiq/ComfyUI_essentials.git \
    https://github.com/welltop-cn/ComfyUI-TeaCache.git \
    https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git \
    https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
    https://github.com/chflame163/ComfyUI_LayerStyle.git \
    https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git \
    https://github.com/yolain/ComfyUI-Easy-Use.git \
    https://github.com/city96/ComfyUI-GGUF.git \
    ; do \
        cd /ComfyUI/custom_nodes; \
        repo_dir=$(basename "$repo" .git); \
        if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then \
            git clone --recursive "$repo" "$repo_dir"; \
        else \
            git clone "$repo" "$repo_dir"; \
        fi; \
        if [ -f "$repo_dir/requirements.txt" ]; then \
            pip install -r "$repo_dir/requirements.txt"; \
        fi; \
        if [ -f "$repo_dir/install.py" ]; then \
            python "$repo_dir/install.py"; \
        fi; \
    done

COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

WORKDIR /
CMD ["/start_script.sh"]