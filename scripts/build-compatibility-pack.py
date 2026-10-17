#!/usr/bin/env python3
"""Stage pinned graphics/font data and a source-inclusive DXVK distribution.

Uses Python's standard library. Missing DXVK inputs invoke the existing source
builder (MinGW-w64 required); missing fonts download from the pinned publisher.
This script never starts Wine, installs a system package, or changes a bottle.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PACK_ID = "portside-compatibility-pack"
FONT_COMMIT = "f8d157532fbfaeda587e826d4cd5b21a49186f7c"
FONT = "NotoSansCJKsc-Regular.otf"
FONT_HASH = "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b"
OFL_HASH = "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"
FONT_BASE = f"https://raw.githubusercontent.com/notofonts/noto-cjk/{FONT_COMMIT}/Sans/"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular file, without symlinks: {path}")
    return path


def checked(path, expected):
    if digest(regular(path)) != expected:
        raise ValueError(f"Pinned checksum mismatch: {path}")
    return path


def read_json(path):
    return json.loads(regular(path).read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def helpers():
    spec = importlib.util.spec_from_file_location("portside_dxvk", ROOT / "scripts/setup-bottle-dxvk.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_pack(pack):
    if pack.is_symlink() or not pack.is_dir():
        raise ValueError(f"Expected a compatibility pack directory: {pack}")
    # No link from a selected pack may reach a local runtime or user data.
    for parent, directories, files in os.walk(pack, followlinks=False):
        for name in directories + files:
            if (Path(parent) / name).is_symlink():
                raise ValueError(f"Symlink in compatibility pack: {Path(parent) / name}")
    metadata = read_json(pack / "manifest.json")
    if metadata.get("schemaVersion") != 1 or metadata.get("id") != PACK_ID:
        raise ValueError("Unrecognized generated compatibility pack manifest.")
    component, manifest = helpers().validate_component(pack / "Components/dxvk-macos")
    pins = read_json(ROOT / "third_party/dxvk-compat/inputs.json")
    for item in (pins["source"], pins["binaries"]):
        checked(component / "source/downloads" / item["filename"], item["sha256"])
    for relative in ("NOTICE.md", "licenses/LICENSE.dxvk", "licenses/LICENSE.portside",
                     "licenses/toolchain/GCC-COPYING.RUNTIME", "licenses/toolchain/GCC-COPYING3",
                     "licenses/toolchain/mingw-w64-AUTHORS", "licenses/toolchain/mingw-w64-COPYING",
                     "source/scripts/build-dxvk-compat.sh", "source/scripts/setup-bottle-dxvk.py",
                     "source/third_party/dxvk-compat/inputs.json", "source/third_party/dxvk-compat/wine-builtin-dxgi-d3d10.patch"):
        regular(component / relative)
    checked(component / "source/third_party/dxvk-compat/wine-builtin-dxgi-d3d10.patch", manifest["patchSHA256"])
    font = pack / "Fonts/noto-cjk"
    checked(font / FONT, FONT_HASH)
    checked(font / "OFL.txt", OFL_HASH)
    provenance = read_json(font / "PROVENANCE.json")
    if provenance.get("commit") != FONT_COMMIT:
        raise ValueError("The font provenance does not match the pinned source commit.")
    return component


def fetch(destination, url, expected):
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                print("Downloading " + url, flush=True)
                with urllib.request.urlopen(url, timeout=60) as response:
                    shutil.copyfileobj(response, stream)
                stream.flush()
                checked(temporary, expected)
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)
    return checked(destination, expected)


def copy_file(source, destination):
    regular(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)


def source_archive(component, version):
    destination = ROOT / "dist" / f"Portside-DXVK-Compat-{version}.tar.gz"
    destination.parent.mkdir(exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for path in [component, *sorted(component.rglob("*"))]:
                        name = f"Portside-DXVK-Compat-{version}"
                        if path != component:
                            name += "/" + path.relative_to(component).as_posix()
                        entry = archive.gettarinfo(str(path), arcname=name)
                        entry.uid = entry.gid = entry.mtime = 0
                        entry.uname = entry.gname = ""
                        entry.mode = 0o755 if path.is_dir() else 0o644
                        if path.is_file():
                            with path.open("rb") as data:
                                archive.addfile(entry, data)
                        else:
                            archive.addfile(entry)
            stream.flush()
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    destination.chmod(0o644)
    destination.with_suffix(destination.suffix + ".sha256").write_text(digest(destination) + "  " + destination.name + "\n")
    print("Source-inclusive DXVK archive: " + str(destination))


def build(args):
    output = Path(os.path.abspath(args.output.expanduser()))
    if args.validate_only:
        validate_pack(output)
        print("Validated compatibility pack: " + str(output))
        return
    component = args.component_dir or ROOT / ".build/dxvk-compat/component"
    if not component.exists() and args.component_dir is None:
        subprocess.run(["bash", str(ROOT / "scripts/build-dxvk-compat.sh")], check=True)
    component, manifest = helpers().validate_component(component)
    fonts = (args.font_dir or ROOT / ".artifacts/downloads/noto-cjk-f8d1575").expanduser()
    if not fonts.exists() and args.font_dir is None:
        fonts = ROOT / ".build/compatibility-downloads/noto-cjk"
        fetch(fonts / FONT, FONT_BASE + "OTF/SimplifiedChinese/" + FONT, FONT_HASH)
        fetch(fonts / "OFL.txt", FONT_BASE + "LICENSE", OFL_HASH)
    checked(fonts / FONT, FONT_HASH)
    checked(fonts / "OFL.txt", OFL_HASH)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and (output.is_symlink() or read_json(output / "manifest.json").get("id") != PACK_ID):
        raise ValueError("Refusing to replace a directory that is not a generated compatibility pack.")
    with tempfile.TemporaryDirectory(prefix=".compatibility-pack-", dir=output.parent) as temporary:
        staged = Path(temporary) / "pack"
        target = staged / "Components/dxvk-macos"
        target.mkdir(parents=True)
        # Explicit payloads exclude build diagnostics containing local build paths.
        for name in ["component.json", *manifest["files"]]:
            copy_file(component / name, target / name)
        definition = ROOT / "third_party/dxvk-compat"
        copy_file(definition / "NOTICE.md", target / "NOTICE.md")
        for source, destination in [("LICENSE.dxvk", "licenses/LICENSE.dxvk"), ("LICENSE.portside", "licenses/LICENSE.portside")]:
            copy_file(definition / source, target / destination)
        toolchain_notices = ["GCC-COPYING.RUNTIME", "GCC-COPYING3", "mingw-w64-AUTHORS", "mingw-w64-COPYING"]
        for name in toolchain_notices:
            copy_file(definition / "toolchain-licenses" / name, target / "licenses/toolchain" / name)
        source_files = ["inputs.json", "README.md", "NOTICE.md", "SETUP.md", "LICENSE.dxvk", "LICENSE.portside",
                        "wine-builtin-dxgi-d3d10.patch", *["toolchain-licenses/" + name for name in toolchain_notices]]
        for name in source_files:
            copy_file(definition / name, target / "source/third_party/dxvk-compat" / name)
        for name in ["build-dxvk-compat.sh", "setup-bottle-dxvk.py"]:
            copy_file(ROOT / "scripts" / name, target / "source/scripts" / name)
        pins = read_json(definition / "inputs.json")
        for item in [pins["source"], pins["binaries"]]:
            source = checked(component / "source/downloads" / item["filename"], item["sha256"])
            copy_file(source, target / "source/downloads" / item["filename"])
        font_target = staged / "Fonts/noto-cjk"
        for name in [FONT, "OFL.txt"]:
            copy_file(fonts / name, font_target / name)
        write_json(font_target / "PROVENANCE.json", {"repository": "https://github.com/notofonts/noto-cjk", "commit": FONT_COMMIT,
                   "font": {"file": FONT, "sha256": FONT_HASH, "url": FONT_BASE + "OTF/SimplifiedChinese/" + FONT},
                   "license": {"file": "OFL.txt", "sha256": OFL_HASH, "url": FONT_BASE + "LICENSE"}})
        write_json(staged / "manifest.json", {"schemaVersion": 1, "id": PACK_ID,
                   "components": {"dxvk-macos": manifest["version"], "noto-cjk-sc": "2.004"}})
        validate_pack(staged)
        # Preserve an existing generated pack until its replacement is complete.
        previous = Path(temporary) / "previous"
        if output.exists():
            os.replace(output, previous)
        try:
            os.replace(staged, output)
        except BaseException:
            if previous.exists():
                os.replace(previous, output)
            raise
    source_archive(output / "Components/dxvk-macos", manifest["version"])
    print("Compatibility data pack: " + str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component-dir", type=Path, help="Existing pinned source-inclusive DXVK component directory")
    parser.add_argument("--font-dir", type=Path, help="Existing pinned Noto OTF and OFL.txt directory")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/compatibility-pack")
    parser.add_argument("--validate-only", action="store_true", help="Validate an existing generated pack without downloads or writes")
    args = parser.parse_args()
    try:
        build(args)
    except Exception as error:
        # Includes the pinned helper's SetupError without importing a second class.
        raise SystemExit("Compatibility pack: " + str(error))


if __name__ == "__main__":
    main()
