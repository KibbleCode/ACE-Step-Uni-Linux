Ace-Step-Uni-Linux

AI-powered step sequencer with cross-platform support for Windows and Linux. AMD hardware required for AI model acceleration.
Features

    Generate step sequences using local AI models (AMD GPU accelerated)
    Real-time audio preview and export
    Standalone and installer-based deployment options
    Cross-platform compatibility (Windows PowerShell/Linux shell)
    Custom WebUI support - create your own interface

Prerequisites

    AMD GPU (RX 5000 series or newer) with ROCm support
    Python 3.8+
    PowerShell 5.1+ (Windows) or Bash 4.0+ (Linux)
    4GB+ RAM recommended for AI model inference
    Audio playback capabilities

Installation
Windows

Run the installer:

BATCH

INSTALL.bat

Or manually execute:

POWERSHELL

.\installer\ACE-Step-Installer.ps1

Linux

Make scripts executable and run:

BASH

chmod +x Linux-Fork/ace-step.sh Linux-Fork/ace-step-standalone.sh
./Linux-Fork/ace-step.sh

For standalone usage:

BASH

./Linux-Fork/ace-step-standalone.sh

WebUI Setup

Important: The WebUI must be manually installed:

    Download your preferred WebUI package
    Click the "WebUI Folder" button in the launcher
    Extract the WebUI files into the opened directory
    Restart the application

Custom WebUI Development

Anyone can create custom WebUIs for this software. The interface communicates via a local API on port 7860. See the docs/custom-webui.md for specifications and examples.
Usage

Launch the application:

BASH

# Windows
.\installer\launcher.py

# Linux
python3 Linux-Fork/launcher.py

Download required AI models:

BASH

./Linux-Fork/download_models_qt

File Structure

Ace-Step-Uni-Linux/
├── installer/
│   ├── ACE-Step-Installer.ps1
│   └── launcher.py
├── Linux-Fork/
│   ├── ace-step.sh
│   ├── ace-step-standalone.sh
│   ├── download_models_qt
│   └── launcher.py
├── INSTALL.bat
├── LICENSE
├── Track-Example.mp3
└── UNINSTALL.bat

License

This project is licensed under the MIT License - see the LICENSE file for details.
Uninstallation

Windows: Run UNINSTALL.bat

Linux: Remove installation directory and associated config files in ~/.config/ace-step/
