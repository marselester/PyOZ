# Installation

## Installing PyOZ CLI

The easiest way to get the `pyoz` CLI:

```bash
pip install pyoz
```

This installs prebuilt binaries for Linux (x86_64/aarch64), macOS (x86_64/arm64), and Windows (x86_64/arm64). No compilation needed.

Alternatively, download a binary from [GitHub Releases](https://github.com/pyozig/PyOZ/releases) or build from source with `zig build cli`.

## Requirements

- **Zig** 0.15.0 or later
- **Python** 3.8 or later (with development headers)

!!! note "Python Version Support"
    PyOZ supports Python 3.8 through 3.13. Testing is performed on Python 3.9 - 3.13.

## Installing Zig

### Linux

```bash
# Download from ziglang.org
wget https://ziglang.org/download/0.15.0/zig-linux-x86_64-0.15.0.tar.xz
tar xf zig-linux-x86_64-0.15.0.tar.xz
export PATH=$PATH:$(pwd)/zig-linux-x86_64-0.15.0
```

Or use your package manager:

```bash
# Ubuntu/Debian (may have older version)
sudo apt install zig

# Arch Linux
sudo pacman -S zig
```

### macOS

```bash
# Homebrew
brew install zig

# Or download from ziglang.org
```

### Windows

Download from [ziglang.org](https://ziglang.org/download/) and add to PATH.

## Installing Python Development Headers

### Linux

```bash
# Ubuntu/Debian
sudo apt install python3-dev

# Fedora
sudo dnf install python3-devel

# Arch Linux
sudo pacman -S python
```

### macOS

Python development headers are included with the system Python or Homebrew Python.

### Windows

Install Python from [python.org](https://python.org) with the "Install development files" option.

## Setting Up a PyOZ Project

### Option 1: Use the CLI (Recommended)

The `pyoz` CLI handles all project setup, build configuration, and Python embedding automatically:

```bash
pyoz init mymodule
cd mymodule
pyoz build
```

This generates the correct `build.zig`, `build.zig.zon`, and `pyproject.toml` — no manual configuration needed. See the [Quick Start](quickstart.md) for a full walkthrough.

### Option 2: Clone the Repository

```bash
git clone https://github.com/pyozig/PyOZ.git
cd PyOZ
zig build example  # Build the example module
```

## Verifying Installation

After building with `pyoz build`, install and test:

```bash
pip install dist/mymodule-*.whl
python3 -c "import mymodule; print(mymodule.add(2, 3))"
```

## Next Steps

Continue to the [Quick Start](quickstart.md) guide to build your first PyOZ module.
