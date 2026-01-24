# ComfyUI Distributed Pod

A high-performance Docker container for running ComfyUI with distributed computing capabilities. This template enables multi-GPU workflows for AI image and video generation, with pre-installed custom nodes, optimized settings, and **smart model presets**.

## Features

* **Distributed Computing**: Built-in support for [ComfyUI-Distributed](https://github.com/robertvoy/ComfyUI-Distributed) workflows across multiple GPUs/pods.
* **Smart Model Presets**: Environment variables to automatically download and configure models (Wan 2.2, LTX-2, Qwen, SAM3) on launch.
* **Nunchaku Integration**: Optional pre-installed support for Nunchaku (SVD/Flux quantization and inference).
* **SageAttention Support**: Optional high-performance attention mechanism for faster inference.
* **Pre-installed Custom Nodes**: Essential nodes including WanVideoWrapper, KJNodes, Easy Use, and more.
* **CUDA Optimized**: Built on NVIDIA CUDA 12.8.1 with cuDNN support.
* **Jupyter Lab**: Integrated Jupyter Lab for easy file management.

## Prerequisites

* RunPod account with GPU pods.
* Basic understanding of ComfyUI.
* (Optional) Multiple pods for distributed workflows.

## Quick Start on RunPod

### Option 1: Use Pre-built Template

1. Go to RunPod and select "Deploy".

> **Note:** Ensure you filter pods by CUDA version 12.8 or higher.

2. Search for "ComfyUI Distributed Pod" template.
3. Configure your pod settings (see Environment Variables below) and deploy.

### Option 2: Deploy from Docker

```bash
docker pull robertvoy/comfyui-distributed-pod:latest

```

## Configuration & Environment Variables

This image uses environment variables to control installed nodes and model downloads. Set these in your RunPod configuration to customize the instance.

### General Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `SAGE_ATTENTION` | `true` | Set to `false` to disable building SageAttention. |
| `DISTRIBUTED_BRANCH` | `main` | Select a specific branch for ComfyUI-Distributed. |
| `HF_API_TOKEN` | - | Required for downloading gated models (via Presets). |

### ⚠️ SageAttention Usage (Important)

**SageAttention is NOT enabled globally by default**, even if `SAGE_ATTENTION` is set to `true`.

* **Why?** SageAttention is known to break **Qwen Image** models. To allow users to mix Qwen and other models in the same session, we do not force the `--use-sage-attention` launch argument.
* **How to use:** If you want to use SageAttention (e.g., for Wan 2.2 or LTX), please add the **`Patch Model with SageAttention`** node to your workflow and connect it to your diffusion model.

---

### Model Presets

Set any of the following to `true` to automatically download the relevant models, LoRAs, and text encoders to the correct directories on startup.

| Preset Variable | Models Included |
| --- | --- |
| `PRESET_LTX2` | **LTX-2 19B Dev**, Gemma 3 12B, Spatial Upscaler, Distilled LoRA. |
| `PRESET_WAN_2_2_T2V` | **Wan 2.2 T2V** FP16 (Low/High Noise 14B), UMT5 XXL, VAE, Lightning LoRAs. |
| `PRESET_WAN_2_2_I2V` | **Wan 2.2 I2V** FP16 (Low/High Noise 14B), UMT5 XXL, VAE, Lightning LoRAs. |
| `PRESET_WAN_2_1_VACE` | **Wan 2.1 VACE**, UMT5 XXL, VAE, CausVid LoRA. |
| `PRESET_VIDEO_UPSCALER` | **Wan 2.2 (FP8)**, UMT5 XXL, VAE, 4xNomos8kDAT, Lightning LoRAs. |
| `PRESET_QWEN_EDIT_2511` | **Qwen Image Edit 2.5** BF16, Qwen VL 7B, VAE, Lightning, Next Scene & Camera Angle LoRAs. |
| `PRESET_ZIMAGE_TURBO` | **Z-Image Turbo**, Qwen 3 4B, VAE. |
| `PRESET_SAM3` | **SAM3 Model** (and installs ComfyUI-Easy-Sam3 node). |
| `PRESET_FLUX_2_KLEIN_9B` | **FLUX.2 Klein 9B Model**, VAE etc. |

## 📁 Directory Structure

```
/ComfyUI              # Main ComfyUI installation
/workspace            # Persistent storage (Models go here)
  ├── ComfyUI/models  # Mapped model paths
  └── ...

```

## Included Workflows

The template includes several pre-configured distributed workflows located in `/ComfyUI/user/default/workflows`:

1. **distributed-txt2img.json**
2. **distributed-upscale.json**
3. **distributed-upscale-batch.json**
4. **distributed-upscale-video.json**
5. **distributed-wan.json**

## Pre-installed Custom Nodes

* **Core:** ComfyUI-Distributed, KJNodes, ComfyUI Essentials, rgthree-comfy
* **Video:** ComfyUI-WanVideoWrapper, VideoHelperSuite, Frame Interpolation
* **Generation/Editing:** ComfyUI-nunchaku, ComfyUI-Easy-Sam3, ComfyUI-Inpaint-CropAndStitch
* **Utility:** LayerStyle & LayerStyle Advance, Easy-Use, GGUF support

## Using Distributed Features

To use the distributed capabilities:

1. Ensure ports `8189-8191` are exposed on worker nodes.
2. Configure the Master node to point to the Worker IPs.
3. Learn more about the setup at [ComfyUI-Distributed](https://github.com/robertvoy/ComfyUI-Distributed).