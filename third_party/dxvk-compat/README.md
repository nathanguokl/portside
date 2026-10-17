# Optional DXVK-macOS compatibility component

This directory contains source inputs and build instructions for an optional per-bottle Direct3D 10/11 backend. The frontend does not patch binaries or upstream source at launch. The altered wrapper is compiled separately, with its change and provenance recorded.

## Build

On macOS with Python 3, install the cross-compilers from the official Homebrew core registry. The pinned component was built with Homebrew `mingw-w64 14.0.0_3`, whose compilers report GCC 16.2.0:

```sh
brew install mingw-w64
bash scripts/build-dxvk-compat.sh
```

The build fetches source at a pinned commit and ordinary release binaries from the official Gcenx GitHub repository, verifies their SHA-256 digests against `inputs.json`, applies `wine-builtin-dxgi-d3d10.patch`, and compiles only the two architecture variants of `d3d10core.dll`. It pairs them with unmodified upstream `d3d11.dll` files.

Before publishing, all four DLLs must match the pinned output hashes in `inputs.json`. A mismatch reports the required toolchain and preserves the previously staged component/archive. Supporting different compiler output requires an intentional component version/pin update and fresh application verification; the setup helper will not silently accept it.

Outputs:

- `.build/dxvk-compat/component/x32/{d3d10core,d3d11}.dll`
- `.build/dxvk-compat/component/x64/{d3d10core,d3d11}.dll`
- `.build/dxvk-compat/component/component.json`, including DLL hashes and toolchain versions.
- `dist/Portside-DXVK-Compat-1.10.3-portside1.tar.gz`, its recorded checksum, notices, source, and reproduction tools.

Build products and downloaded archives remain in ignored directories. No DLLs are committed. Set `PORTSIDE_DXVK_BUILD_DIR` to change the build/cache directory. The build does not run Wine or alter a bottle, Wine installation, or frontend source.

The distributed component contains the full pinned upstream source archive, exact patch, pinned upstream binary archive, and a standalone source layout. To rebuild an unpacked component, change into its `source/` directory and run:

```sh
bash scripts/build-dxvk-compat.sh
```

That build uses its included archives, after checksum validation, without fetching them again. The source archive also contains upstream instructions for rebuilding the unchanged D3D11 implementation. Building this wrapper requires only the smaller MinGW cross-compiler toolchain, without Meson or shader compilation.

The component also includes `source/scripts/setup-bottle-dxvk.py` for independent per-bottle setup and removal. See `source/third_party/dxvk-compat/SETUP.md` for its commands and safeguards.

## Change

DXVK's D3D10 wrapper originally calls `IDXGIAdapter::CheckInterfaceSupport(ID3D10Device)` first. Wine's builtin DXGI evaluates WineD3D capabilities for that call and rejects adapters below feature level 10.0. This can reject the device before DXVK's Vulkan implementation starts.

The patch removes that preliminary guard. The existing `D3D11CoreCreateDevice` call still validates the actual requested feature level before creating a device. All other wrapper behavior remains upstream code. See `NOTICE.md` and `LICENSE.dxvk` for attribution and the full upstream license.

## Integration contract

Offer this as an optional per-bottle backend. Setup should validate `component.json`, architecture, and file hashes; back up any replaced managed-prefix DLLs; install x32 files in `drive_c/windows/syswow64` and x64 files in `drive_c/windows/system32`; and set `d3d11,d3d10core=n,b;dxgi=b`. Keep Wine's builtin `dxgi.dll`; the upstream repack deliberately excludes DXGI and D3D9 DLLs. Store the component version and selection with the bottle. Restore prior DLLs and overrides when disabling it.

Wine >=7.1 and MoltenVK >=1.2.0 are the upstream fork's stated requirements. The DLLs require Wine with x86 and x64 support; they are not macOS executables. Avoid enabling `DXVK_ASYNC` by default. The source build itself does not establish compatibility with a specific Windows app.

## Recorded build tools

The initial Mac build used official Homebrew `mingw-w64 14.0.0_3`, whose compilers report GCC 16.2.0. Its installation also upgraded `isl 0.27` to `0.28` and `libmpc 1.3.1` to `1.4.1`. The script records the compiler version for each rebuilt DLL rather than assuming identical output across toolchain releases.

`LICENSE.portside` covers only Portside's original build tooling/additions. Upstream-derived code and changes retain the upstream zlib/libpng license. Compiler runtime notices are under `toolchain-licenses/` and are copied into the distribution.
