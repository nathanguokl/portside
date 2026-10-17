# Portside DXVK compatibility component

This optional component derives from **DXVK-macOS** by Philip Rebohle, Joshua Ashton, Gcenx, and its other contributors. DXVK-macOS is a fork of DXVK. The upstream zlib/libpng license is preserved in `licenses/LICENSE.dxvk` (or `LICENSE.dxvk` in the source definition).

Portside's `1.10.3-portside1` component uses the upstream release `v1.10.3-20230507-repack`, commit `8f1e28deed3ad30802f7e1bdff428ec14e6e7817`. The `d3d11.dll` files are unmodified upstream binaries. The `d3d10core.dll` files are **altered versions built from source**, not official DXVK-macOS release binaries.

The change removes the preliminary WineD3D capability check from `D3D10CoreCreateDevice`. Wine's builtin DXGI can report a maximum feature level of 9.3 for WineD3D even when DXVK's Vulkan backend can initialize the requested 10.0 device. The wrapper now delegates that decision to DXVK's existing D3D11 device creation and feature validation. It does not modify those feature checks.

Upstream repository: https://github.com/Gcenx/DXVK-macOS

Pinned inputs, their recorded SHA-256 digests, the exact patch, full upstream source archive, and reproduction tooling are included under `source/`. The ordinary release archive's digest is a digest recorded by Portside from the downloaded asset; the release did not publish a separate checksum file.

The build statically links compiler runtime support. MinGW-w64 and GCC runtime notices are preserved under `licenses/toolchain/`. The upstream source archive preserves the notices in its bundled headers. Portside's original build tooling uses the MIT license in `licenses/LICENSE.portside`; upstream-derived code retains the zlib/libpng license.

Wine, MoltenVK, and Rosetta are external runtime dependencies and are not part of this component. This component supports a Direct3D 10/11 translation path; it does not provide Direct3D 9 or Direct3D 12 support. Application compatibility requires real testing.
