NPROC        := $(shell nproc)
INSTALL_USER := ollama
CURRENT_USER := $(shell whoami)
VERSION      := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
RELEASE_NAME := ollama-linux-arm64-jetson

# Go ldflags to embed version into the binary (matches upstream build convention)
GO_LDFLAGS := -s -w -X=github.com/ollama/ollama/version.Version=$(VERSION) -X=github.com/ollama/ollama/server.mode=release

# Detectar JetPack para elegir backend CUDA correcto
JETPACK_VERSION := $(shell grep -oP 'R\d+' /etc/nv_tegra_release 2>/dev/null | tr -d 'R' || echo "0")

ifeq ($(JETPACK_VERSION),39)
    # JetPack 7.x (Jetson Linux 39.x) — CUDA 13.x
    CUDA_BACKEND := cuda_v13
    CUDA_ARCHS   := 110
else
    $(warning Unrecognized Jetson Linux revision R$(JETPACK_VERSION). Defaulting to cuda_v13 with sm_110.)
    CUDA_BACKEND := cuda_v13
    CUDA_ARCHS   := 110
endif

CMAKE_COMMON := -DCMAKE_DISABLE_FIND_PACKAGE_Vulkan=ON \
    -DOLLAMA_LLAMA_BACKENDS=$(CUDA_BACKEND) \
    -DCMAKE_CUDA_ARCHITECTURES="$(CUDA_ARCHS)" \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DGGML_CPU_ALL_VARIANTS=OFF

.PHONY: all clean install uninstall release

all:
	cmake -B build $(CMAKE_COMMON) -DOLLAMA_VERSION=$(VERSION)
	cmake --build build --parallel $(NPROC)
	go build -trimpath -ldflags "$(GO_LDFLAGS)" -o ollama .
	go build -o ollama-drop-cache ./cmd/jetson-drop-cache/

install: all
	# Create ollama user if it doesn't exist
	id $(INSTALL_USER) >/dev/null 2>&1 || \
		sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama $(INSTALL_USER)
	# Add ollama to render group if it exists
	getent group render >/dev/null 2>&1 && \
		sudo usermod -a -G render $(INSTALL_USER) || true
	# Add ollama to video group if it exists
	getent group video >/dev/null 2>&1 && \
		sudo usermod -a -G video $(INSTALL_USER) || true
	# Add current user to ollama group
	sudo usermod -a -G $(INSTALL_USER) $(CURRENT_USER)
	# Create model storage directory
	sudo install -o ollama -g ollama -m 755 -d /usr/share/ollama
	sudo install -o ollama -g ollama -m 755 -d /usr/share/ollama/.ollama
	sudo install -o ollama -g ollama -m 755 -d /usr/share/ollama/.ollama/models
	# Install binary and libs
	sudo install -o root -g root -m 755 ollama /usr/local/bin/ollama
	sudo mkdir -p /usr/local/lib/ollama
	# -a preserves symlinks and copies subdirectories (e.g. cuda_v13/)
	sudo cp -a build/lib/ollama/* /usr/local/lib/ollama/
	# Symlink cuda_jetpack7 → cuda_v13 so Ollama matches JETSON_JETPACK=7.x with our backend
	sudo ln -sfn cuda_v13 /usr/local/lib/ollama/cuda_jetpack7
	# Install drop-cache helper with setuid root, group ollama
	sudo install -o root -g ollama -m 4750 ollama-drop-cache /usr/local/sbin/ollama-drop-cache
	# Install and enable systemd service
	sudo cp scripts/ollama.service /etc/systemd/system/ollama.service
	sudo systemctl daemon-reload
	sudo systemctl enable ollama
	sudo systemctl restart ollama

uninstall:
	# Stop and disable service
	sudo systemctl stop ollama || true
	sudo systemctl disable ollama || true
	# Remove binary and libs
	sudo rm -f /usr/local/bin/ollama
	sudo rm -rf /usr/local/lib/ollama
	sudo rm -f /usr/local/sbin/ollama-drop-cache
	# Remove service files
	sudo rm -f /etc/systemd/system/ollama.service
	sudo rm -f /etc/systemd/system/ollama.service.d/override.conf
	sudo systemctl daemon-reload
	# NOTE: models and ollama user are preserved intentionally
	# To also remove them run:
	#   sudo userdel -r ollama
	#   sudo rm -rf /usr/share/ollama

release: all
	mkdir -p release/lib/ollama
	cp ollama release/
	cp ollama-drop-cache release/
	# Copy all shared libs, symlinks, and backend subdirs (e.g. cuda_v13/)
	cp -a build/lib/ollama/* release/lib/ollama/
	cp scripts/ollama.service release/
	tar -czf $(RELEASE_NAME)-$(VERSION).tar.gz -C release .
	rm -rf release
	@echo "Created $(RELEASE_NAME)-$(VERSION).tar.gz"

clean:
	rm -rf build ollama ollama-drop-cache release *.tar.gz
