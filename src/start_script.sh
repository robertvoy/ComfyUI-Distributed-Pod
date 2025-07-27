#!/bin/bash
# Remove existing directory if it exists, then clone fresh
rm -rf ComfyUI-Distributed-Pod
git clone https://github.com/robertvoy/ComfyUI-Distributed-Pod.git
mv ComfyUI-Distributed-Pod/src/start.sh /start.sh
chmod +x /start.sh
bash /start.sh