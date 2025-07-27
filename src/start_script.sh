#!/bin/bash
# Remove existing directory if it exists, then clone fresh
rm -rf ComfyUI-Distributed-Pod

# Try to clone from GitHub, with fallback to local copy if it fails
if git clone https://github.com/robertvoy/ComfyUI-Distributed-Pod.git; then
    echo "Successfully cloned from GitHub"
    mv ComfyUI-Distributed-Pod/src/start.sh /start.sh
    chmod +x /start.sh
else
    echo "GitHub clone failed, checking for fallback start.sh..."
    if [ -f "/fallback_start.sh" ]; then
        echo "Using fallback start.sh"
        cp /fallback_start.sh /start.sh
        chmod +x /start.sh
    else
        echo "No fallback available, container cannot start"
        exit 1
    fi
fi

bash /start.sh