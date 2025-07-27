# Use multi-stage build with caching optimizations
FROM pytorch/pytorch:nightly-devel-cuda12.8-cudnn9-ubuntu24.04 AS base

# Consolidated environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# Install system dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ffmpeg ninja-build git aria2 git-lfs wget vim \
        libgl1 libglib2.0-0 build-essential gcc && \
    apt-get autoremove -y && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

# Core Python tooling (use pip from the Conda env)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir packaging setuptools wheel && \
    rm -rf /root/.cache/pip/* /tmp/* && pip cache purge

# Runtime libraries
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir pyyaml gdown triton comfy-cli jupyterlab jupyterlab-lsp \
        jupyter-server jupyter-server-terminals \
        ipykernel jupyterlab_code_formatter && \
    rm -rf /root/.cache/pip/* /tmp/* && pip cache purge

# ------------------------------------------------------------
# ComfyUI install
# ------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/pip \
    /usr/bin/yes | comfy --workspace /ComfyUI install && \
    rm -rf /root/.cache/pip/* /tmp/* && pip cache purge

# Builder stage for custom nodes (to keep final image slimmer)
FROM base AS builder

# Install custom nodes
RUN for repo in \
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
            pip install --no-cache-dir -r "$repo_dir/requirements.txt" && \
            rm -rf /root/.cache/pip/* /tmp/*; \
        fi; \
        if [ -f "$repo_dir/install.py" ]; then \
            python "$repo_dir/install.py"; \
        fi; \
    done && \
    find /ComfyUI -type d -name "__pycache__" -exec rm -rf {} + && \
    rm -rf /tmp/*

# Final stage
FROM base AS final

# Copy ComfyUI and custom nodes from builder
COPY --from=builder /ComfyUI /ComfyUI

# Additional final installs
RUN pip install --no-cache-dir opencv-python && \
    rm -rf /root/.cache/pip/* /tmp/* && pip cache purge

# Copy and set up start script
COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

CMD ["/start_script.sh"]