# ComfyUI Distributed Pod

A high-performance Docker container for running ComfyUI with distributed computing capabilities on RunPod. This template enables multi-GPU workflows for AI image and video generation, with pre-installed custom nodes and optimized settings.

## 🚀 Features

- **Distributed Computing**: Built-in support for ComfyUI-Distributed workflows across multiple GPUs/pods
- **Pre-installed Custom Nodes**: Essential nodes for advanced workflows including upscaling, video processing, and more
- **CUDA Optimized**: Built on NVIDIA CUDA 12.8.1 with cuDNN support
- **Jupyter Lab**: Integrated Jupyter Lab for easy file management and code editing
- **SageAttention Support**: Optional high-performance attention mechanism for faster inference
- **Ready-to-Use Workflows**: Includes distributed workflows for various tasks

## 📋 Prerequisites

- RunPod account with GPU pods
- Basic understanding of ComfyUI
- (Optional) Multiple pods for distributed workflows

## 🛠️ Quick Start on RunPod

### Option 1: Use Pre-built Template
1. Go to RunPod and select "Deploy"
> Make sure you filter pods by CUDA version 12.8
2. Search for "ComfyUI Distributed Pod" template
3. Configure your pod settings and deploy

### Option 2: Deploy from Docker
```bash
docker pull robertvoy/comfyui-distributed-pod:latest
```

### Option 3: Build from Source
```bash
git clone https://github.com/robertvoy/ComfyUI-Distributed-Pod.git
cd ComfyUI-Distributed-Pod
docker build -t comfyui-distributed-pod .
```

## 🔧 Configuration

### Environment Variables

- `SAGE_ATTENTION`: Set to `false` to disable SageAttention
- `CIVITAI_API_TOKEN`: Your CivitAI API token for model downloads
- `HF_API_TOKEN`: Your Hugging Face API token for model downloads

### Exposed Ports

- **8188**: ComfyUI Web Interface
- **8888**: Jupyter Lab
- **8189,8190,8191**: For workers if using multi-GPU pods. Add more if you need

## 📁 Directory Structure

```
/ComfyUI              # Main ComfyUI installation
/workspace            # Persistent storage for models and outputs (if using network drive)
```

## 🎨 Included Workflows

The template includes several pre-configured distributed workflows:

1. **distributed-txt2img.json**
2. **distributed-upscale.json**
3. **distributed-upscale-batch.json**
4. **distributed-upscale-video.json**
5. **distributed-wan.json**

## 🔌 Pre-installed Custom Nodes

- ComfyUI-Distributed
- UltimateSDUpscale
- KJNodes
- rgthree-comfy
- VideoHelperSuite
- ComfyUI-Impact-Pack
- ControlNet Auxiliary
- ComfyUI Essentials
- TeaCache
- Frame Interpolation
- LayerStyle & LayerStyle Advance
- Easy-Use
- GGUF support

## 🚀 Using Distributed Features

Learn more about [ComfyUI-Distributed](https://github.com/robertvoy/ComfyUI-Distributed)
