<p align="center">
  <a href="https://ollama.com">
    <img src="https://github.com/ollama/ollama/assets/3325447/0d0b44e2-8f4a-4e99-9b52-a5c1c741c8f7" alt="ollama" width="200"/>
  </a>
</p>

# Ollama for NVIDIA Jetson — nvmap cache workaround

This is a **fork of [Ollama](https://github.com/ollama/ollama)** with specific patches to run on **NVIDIA Jetson AGX Thor** with JetPack 7.x.

The main addition is a **workaround for the `nvmap` page-cache leak**: on Tegra/Jetson, the CUDA driver retains physical pages after `cudaFree()`. Over time this exhausts memory and prevents loading new models. This fork automatically drops those caches after each model unload.

> **Status**: tested on Jetson AGX Thor with JetPack 7.2 (CUDA 13.2, compute capability 11.0). Builds cleanly on Ubuntu 24.04 for arm64.

---

## What this fork changes

| File | Change |
|------|--------|
| `Makefile` | JetPack auto-detection, disables broken UI build, selects correct CUDA backend/arch |
| `scripts/ollama.service` | systemd service with `OLLAMA_JETSON_DROP_CACHE=1`, `OLLAMA_GPU_OVERHEAD`, and correct `JETSON_JETPACK` |
| `cmd/jetson-drop-cache/` | Small setuid helper that writes `3` to `/proc/sys/vm/drop_caches` to reclaim nvmap pages |
| `server/sched.go` | Calls the helper automatically after `runner.unload()` when `OLLAMA_JETSON_DROP_CACHE=1` |
| `envconfig/config.go` | Adds `OLLAMA_JETSON_DROP_CACHE` env var |
| `cmake/local.cmake` | Disables `GGML_CPU_ALL_VARIANTS` (fixes ARMv9 `+sme` build error on GCC 12/13) |

---

## Prerequisites

- NVIDIA Jetson AGX Thor with JetPack 7.x
- Ubuntu 24.04 (arm64)
- Go 1.26+, CMake 3.24+, GCC, CUDA toolkit

```bash
sudo apt update
sudo apt install -y build-essential cmake git golang-go
```

---

## Build

```bash
git clone https://github.com/jmmunoz-code/ollama.git
cd ollama
make clean
make all
```

The Makefile auto-detects your JetPack version:

| JetPack | Detected | Backend | CUDA architectures |
|---------|----------|---------|-------------------|
| 7.x (R39) | `JETPACK_VERSION=39` | `cuda_v13` | `sm_110` |

If auto-detection fails, override `CUDA_BACKEND` and `CUDA_ARCHS` manually in `Makefile`.

### Why these flags?

- `-DLLAMA_BUILD_UI=OFF` — prevents a build failure where `llama-server` tries to download web assets from Hugging Face during compilation.
- `-DLLAMA_USE_PREBUILT_UI=OFF` — same reason.
- `-DGGML_CPU_ALL_VARIANTS=OFF` — prevents `cc1: error: invalid feature modifier 'sme'` on GCC versions that don't support ARMv9.2 `+sme`.

---

## Install

```bash
make install
```

This will:

1. Create the `ollama` user and groups (`render`, `video`)
2. Install the `ollama` binary to `/usr/local/bin/ollama`
3. Install libraries and the `cuda_v13` backend to `/usr/local/lib/ollama/`
4. Create a `cuda_jetpack7 → cuda_v13` symlink so Ollama matches `JETSON_JETPACK=7.x`
5. Install the setuid helper `ollama-drop-cache` to `/usr/local/sbin/ollama-drop-cache`
6. Install and start the systemd service

### Verify

```bash
# Check the service is running
sudo systemctl status ollama

# Check GPU is detected
ollama run qwen2.5vl:3b
ollama ps
```

Expected output:

```
NAME            ID              SIZE      PROCESSOR    CONTEXT    UNTIL
qwen2.5vl:3b    fb90415cde1e    7.5 GB    100% GPU     128000     4 minutes from now
```

If you see `100% CPU`, the GPU backend is not being picked up. Check `journalctl -u ollama` for discovery errors.

---

## Uninstall

```bash
make uninstall
```

Models and the `ollama` user are preserved intentionally. To fully remove:

```bash
sudo userdel -r ollama
sudo rm -rf /usr/share/ollama
```

---

## How the nvmap workaround works

1. When Ollama unloads a model, `server/sched.go` checks `OLLAMA_JETSON_DROP_CACHE`
2. If enabled and running on Jetson (`/etc/nv_tegra_release` exists), it calls `/usr/local/sbin/ollama-drop-cache`
3. The helper is installed **setuid root** with group `ollama`, so the unprivileged `ollama` user can run it
4. The helper does `sync()` and writes `3` to `/proc/sys/vm/drop_caches`, forcing the kernel to reclaim `nvmap` pages
5. Memory is freed and the next model load succeeds

---

## Environment variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `OLLAMA_HOST` | Bind address | `0.0.0.0:11434` |
| `OLLAMA_GPU_OVERHEAD` | Reserved GPU memory (bytes) | `2147483648` (2 GB) |
| `OLLAMA_JETSON_DROP_CACHE` | Drop nvmap caches after unload | `1` |
| `JETSON_JETPACK` | JetPack version hint | auto-detected |
| `OLLAMA_NUM_PARALLEL` | Parallel requests | `1` |
| `OLLAMA_KEEP_ALIVE` | Model unload timeout | `5m` |

See `envconfig/config.go` for the full list.

---

## Hardware tested

| Device | JetPack | CUDA | GPU compute capability | Status |
|--------|---------|------|------------------------|--------|
| Jetson AGX Thor | 7.2 | 13.2 | 11.0 (`sm_110`) | ✅ Verified |

---

## License

Same as upstream Ollama: [MIT](LICENSE)
