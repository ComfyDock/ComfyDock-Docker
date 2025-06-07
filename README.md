# Base Dockerfiles for ComfyUI

This repo contains a collection of dockerfiles for running ComfyUI with a particular version and flavor of CUDA.

It is meant to be used alongside my [ComfyUI Environment Manager tool](https://github.com/akatz-ai/ComfyUI-Environment-Manager)

Docker images built and pushed to Dockerhub and can be [found here](https://hub.docker.com/repository/docker/akatzai/comfyui-env/tags)

**Note:** I am not a security expert and am open to Issues and PRs that can help to harden the Images included in this repo.

## Updates
(06/07/2025): Removed CUDA 11.8 support for new images (Comfy versions v0.3.40+) due to incompatibilities with xformers and pytorch. Added full CUDA 12.8 support. Fixed updating ComfyUI via manager inside containers.

(04/03/2025): Increased security of docker images by switching from 'root' user inside containers to 'comfy' user. Modified permissions of /app directory to enable full read/write for all users. Available for images v0.3.29+.

## Testing

To build the image locally, run the following command:
```bash
docker build \
  --build-arg COMFYUI_VERSION=master \
  --build-arg CUDA_VERSION=12.4 \
  --build-arg PYTHON_VERSION=3.12 \
  --build-arg PYTORCH_VERSION=stable \
  --tag comfydock-env:master-py3.12-cuda12.4 \
  --file Dockerfile \
  .
```

To run the image, run the following command:
```bash
docker run -it --rm --gpus all comfydock-env:master-py3.12-cuda12.4
```

