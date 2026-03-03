# pyoz init

Initialize a new PyOZ project with the recommended directory structure and configuration.

## Usage

```bash
pyoz init [options] [name]
```

## Arguments

| Argument | Description |
|----------|-------------|
| `name` | Project name (required unless using `--path`) |

## Options

| Option | Description |
|--------|-------------|
| `-p, --path` | Initialize in current directory instead of creating new one |
| `-k, --package` | Create a Python package directory layout (see below) |
| `-l, --local <path>` | Use local PyOZ path instead of fetching from URL |
| `-h, --help` | Show help message |

## Examples

```bash
# Create new project directory
pyoz init myproject

# Initialize in current directory
pyoz init --path

# Create with package directory layout
pyoz init --package myproject

# Use local PyOZ for development
pyoz init --local /path/to/PyOZ myproject
```

## Generated Structure

### Flat layout (default)

```
myproject/
├── src/
│   └── lib.zig          # Main module source
├── build.zig            # Zig build configuration
├── build.zig.zon        # Zig package manifest
└── pyproject.toml       # Python package configuration
```

Installs as a single `.so` file: `site-packages/myproject.so`

### Package layout (`--package`)

```
myproject/
├── src/
│   └── lib.zig          # Main module source
├── myproject/
│   └── __init__.py      # Re-exports from native extension
├── build.zig
├── build.zig.zon
└── pyproject.toml       # module-name = "_myproject", py-packages = ["myproject"]
```

Installs as a proper Python package: `site-packages/myproject/__init__.py` + `_myproject.so`

The `--package` flag is recommended for non-trivial projects because it lets you combine the native extension with pure Python code in the same importable package. The native module is automatically prefixed with an underscore (`_myproject`) to avoid name collisions with the package directory, and `__init__.py` re-exports all native symbols.

The generated `src/lib.zig` contains a minimal working module with an example `add` function. Edit this file to add your functions and classes.

## Next Steps

After initialization:

```bash
cd myproject
pyoz develop                                        # Build and install
python -c "import myproject; print(myproject.add(1, 2))"  # Test
```

See [pyoz build](build.md) for build options and [Configuration](configuration.md) for project settings.
