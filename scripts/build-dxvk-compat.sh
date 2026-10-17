#!/bin/bash
# Optional, source-patched DXVK component. This never runs Wine or edits a bottle.
set -euo pipefail
PORTSIDE_SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$PORTSIDE_SOURCE_ROOT" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

root = Path(sys.argv[1])
definition = root / "third_party/dxvk-compat"
inputs = json.loads((definition / "inputs.json").read_text())
build = Path(os.environ.get("PORTSIDE_DXVK_BUILD_DIR", root / ".build/dxvk-compat")).resolve()
downloads = build / "downloads"
downloads.mkdir(parents=True, exist_ok=True)

def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()

def run(arguments, cwd=None):
    print("+ " + " ".join(str(value) for value in arguments), flush=True)
    subprocess.run([str(value) for value in arguments], check=True, cwd=cwd)

def fetch(item):
    destination = downloads / item["filename"]
    if not destination.exists():
        # The repository keeps local downloads outside source control. The second
        # location is the offline source payload included in a component archive.
        included = next((path for path in (root / ".artifacts/downloads" / item["filename"],
                                            root / "downloads" / item["filename"]) if path.exists()), None)
        if included is not None:
            shutil.copyfile(included, destination)
        else:
            print("Downloading " + item["url"], flush=True)
            with urllib.request.urlopen(item["url"]) as response, destination.open("wb") as output:
                shutil.copyfileobj(response, output)
    actual = sha256(destination)
    if actual != item["sha256"]:
        raise SystemExit(f"Checksum mismatch for {destination}: {actual}; remove that cached file and retry.")
    return destination

for tool in ("patch", "i686-w64-mingw32-g++", "i686-w64-mingw32-dlltool", "i686-w64-mingw32-windres",
             "x86_64-w64-mingw32-g++", "x86_64-w64-mingw32-dlltool", "x86_64-w64-mingw32-windres"):
    if not shutil.which(tool):
        raise SystemExit(f"Missing {tool}. Install the build toolchain with: brew install mingw-w64")

source_archive = fetch(inputs["source"])
binary_archive = fetch(inputs["binaries"])
with tempfile.TemporaryDirectory(prefix="build-", dir=build) as temporary:
    work = Path(temporary)
    with tarfile.open(source_archive) as archive:
        archive.extractall(work, **({"filter": "data"} if sys.version_info >= (3, 12) else {}))
    with tarfile.open(binary_archive) as archive:
        archive.extractall(work, **({"filter": "data"} if sys.version_info >= (3, 12) else {}))
    source = work / ("DXVK-macOS-" + inputs["upstreamCommit"])
    binaries = work / ("dxvk-macOS-async-" + inputs["upstreamTag"])
    run(["patch", "--directory", source, "-p1", "--input", definition / inputs["patch"]])

    package = work / "component"
    package.mkdir()
    compilers = {}
    for arch, triple, machine in (("x32", "i686-w64-mingw32", "i386"), ("x64", "x86_64-w64-mingw32", "i386:x86-64")):
        output = package / arch
        output.mkdir()
        objects = work / ("objects-" + arch)
        objects.mkdir()
        compiler = shutil.which(triple + "-g++")
        compilers[arch] = subprocess.check_output([compiler, "--version"], text=True).splitlines()[0]
        # x86 stdcall has six 4-byte arguments; the DLL export name is undecorated.
        symbol = "D3D11CoreCreateDevice@24" if arch == "x32" else "D3D11CoreCreateDevice"
        import_definition = objects / "d3d11.def"
        import_definition.write_text("LIBRARY d3d11.dll\nEXPORTS\n    " + symbol + " @18\n")
        imports = objects / "libd3d11.a"
        # Relative names keep temporary build paths out of import-library symbols.
        run([triple + "-dlltool", "-m", machine, "-k", "-d", import_definition.name, "-l", imports.name], cwd=objects)
        resource = objects / "version.o"
        run([triple + "-windres", source / "src/d3d10/version10_core.rc", resource])
        # GNU ld otherwise hashes the output path into the image base.
        # Keep relocation/ASLR support while making builds location-independent.
        image_base = "0x67880000" if arch == "x32" else "0x32b8b0000"
        run([compiler, "-std=c++17", "-O2", "-shared", "-static", "-static-libgcc", "-static-libstdc++",
             "-DNOMINMAX", "-D_WIN32_WINNT=0xa00", "-I" + str(source / "include"),
             "-Wl,--file-alignment=4096", "-Wl,--enable-stdcall-fixup", "-Wl,--add-stdcall-alias",
             "-Wl,--no-insert-timestamp", "-Wl,--image-base," + image_base, "-o", output / "d3d10core.dll",
             source / "src/d3d10/d3d10_core.cpp", source / "src/d3d10/d3d10core.def", resource, imports])
        shutil.copyfile(binaries / arch / "d3d11.dll", output / "d3d11.dll")
        metadata = subprocess.check_output([triple + "-objdump", "-p", output / "d3d10core.dll"], text=True)
        (output / "pe-metadata.txt").write_text(metadata.replace(str(output / "d3d10core.dll"), arch + "/d3d10core.dll"))
        if "D3D11CoreCreateDevice" not in metadata or "D3D10CoreCreateDevice" not in metadata:
            raise SystemExit("Built DLL lacks the expected D3D10 export or D3D11 import.")

    shutil.copytree(definition, package / "source/third_party/dxvk-compat")
    (package / "source/scripts").mkdir()
    shutil.copyfile(root / "scripts/build-dxvk-compat.sh", package / "source/scripts/build-dxvk-compat.sh")
    shutil.copyfile(root / "scripts/setup-bottle-dxvk.py", package / "source/scripts/setup-bottle-dxvk.py")
    (package / "source/downloads").mkdir()
    shutil.copyfile(source_archive, package / "source/downloads" / source_archive.name)
    shutil.copyfile(binary_archive, package / "source/downloads" / binary_archive.name)
    shutil.copyfile(definition / "NOTICE.md", package / "NOTICE.md")
    shutil.copytree(definition / "toolchain-licenses", package / "licenses/toolchain")
    shutil.copyfile(definition / "LICENSE.dxvk", package / "licenses/LICENSE.dxvk")
    shutil.copyfile(definition / "LICENSE.portside", package / "licenses/LICENSE.portside")
    actual_files = {name: sha256(package / name) for name in inputs["expectedDLLs"]}
    if actual_files != inputs["pinnedDLLSHA256"]:
        raise SystemExit("Built DLLs do not match the pinned component. Use Homebrew core mingw-w64 14.0.0_3 "
                         "with GCC 16.2.0. A different toolchain requires a reviewed component version/pin update "
                         "and application verification. No existing component or archive was replaced.\n"
                         + json.dumps({"actual": actual_files, "expected": inputs["pinnedDLLSHA256"]}, indent=2))
    manifest = {
        "schemaVersion": 1, "id": "dxvk-macos", "version": inputs["componentVersion"],
        "upstreamTag": inputs["upstreamTag"], "upstreamCommit": inputs["upstreamCommit"],
        "sourceArchiveSHA256": inputs["source"]["sha256"], "binaryArchiveSHA256": inputs["binaries"]["sha256"],
        "patchSHA256": sha256(definition / inputs["patch"]), "compilers": compilers,
        "files": actual_files,
        "alteredFiles": ["x32/d3d10core.dll", "x64/d3d10core.dll"],
        "requiresWine": ">=7.1", "requiresMoltenVK": ">=1.2.0",
        "dllOverrides": "d3d11,d3d10core=n,b;dxgi=b",
    }
    (package / "component.json").write_text(json.dumps(manifest, indent=2) + "\n")
    destination = build / "component"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.move(package, destination)

distribution = root / "dist"
distribution.mkdir(exist_ok=True)
archive_path = distribution / ("Portside-DXVK-Compat-" + inputs["componentVersion"] + ".tar.gz")
with tarfile.open(archive_path, "w:gz") as archive:
    archive.add(destination, arcname="Portside-DXVK-Compat-" + inputs["componentVersion"])
archive_path.with_suffix(archive_path.suffix + ".sha256").write_text(sha256(archive_path) + "  " + archive_path.name + "\n")
print("Component: " + str(destination))
print("Archive: " + str(archive_path))
PY
