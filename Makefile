NPROC        := $(shell nproc)
INSTALL_USER := ollama
CURRENT_USER := $(shell whoami)
VERSION      := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
RELEASE_NAME := ollama-linux-arm64-jetson-jmmunoz-code

.PHONY: all clean install uninstall release

all:
	cmake -B build -DCMAKE_DISABLE_FIND_PACKAGE_Vulkan=ON
	cmake --build build --parallel $(NPROC)
	go build -o ollama .
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
	sudo cp build/lib/ollama/*.so /usr/local/lib/ollama/
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
	cp build/lib/ollama/*.so release/lib/ollama/
	cp scripts/ollama.service release/
	tar -czf $(RELEASE_NAME)-$(VERSION).tar.gz -C release .
	rm -rf release
	@echo "Created $(RELEASE_NAME)-$(VERSION).tar.gz"

clean:
	rm -rf build ollama ollama-drop-cache release *.tar.gz
