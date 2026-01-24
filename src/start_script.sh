#!/bin/bash
# Remove existing directory if it exists, then clone fresh
cd / || exit
rm -rf ComfyUI-Distributed-Pod
git clone https://github.com/robertvoy/ComfyUI-Distributed-Pod.git;
echo "Successfully cloned from GitHub"
chmod +x ComfyUI-Distributed-Pod/src/start.sh
bash ComfyUI-Distributed-Pod/src/start.sh