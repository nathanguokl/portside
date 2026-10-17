#!/usr/bin/env python3
"""Package only public source inputs; local history, downloads and test artifacts stay private.

Entries are sorted and ZIP timestamps/permissions are normalized. Identical inputs
produce identical archives with the same Python/zlib implementation.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import tempfile
import zipfile


ROOT_FILES = {
    "Package.swift", "Package.resolved", "README.md", "LICENSE", "THIRD_PARTY.md",
    "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "CHANGELOG.md",
    ".gitignore", ".gitattributes", ".editorconfig", ".env.example",
}
ROOT_DIRECTORIES = {"Sources", "Tests", "scripts", "packaging", "profiles", "third_party", "docs", ".github"}
PRIVATE_NAMES = {
    ".git", ".artifacts", ".build", ".downloads", "downloads", "verification", "dist",
    "__pycache__", ".ds_store", ".venv", "venv", "xcuserdata", "deriveddata", ".swiftpm",
    ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", "node_modules",
    "bottles", "logs", "runtimes", "library.json", ".library.lock", ".portside-bottle.json",
}
GENERATED_SUFFIXES = {
    ".pyc", ".pyo", ".xcuserstate", ".exe", ".dll", ".dylib", ".so", ".a", ".o", ".obj", ".lib", ".pdb",
    ".dmg", ".pkg", ".msi", ".msix", ".zip", ".tar", ".gz", ".xz", ".bz2", ".7z",
    ".log", ".dmp", ".mdmp",
    ".p12", ".pfx", ".mobileprovision", ".provisionprofile", ".p8", ".pem", ".key", ".keychain", ".keychain-db",
}
GENERATED_DIRECTORY_SUFFIXES = {".app", ".framework", ".bundle", ".xcuserdatad"}
COMPILED_MAGIC = {b"MZ", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                  b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                  b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca", b"\x7fELF", b"!<arch>\n"}


def private_name(name):
    name = name.lower()
    environment = (name == ".env" or name.startswith(".env.")) and name != ".env.example"
    return name in PRIVATE_NAMES or name.startswith("._") or environment


def public_files(root):
    """Allow public project roots only; never follow a link into another checkout or bottle."""
    root = root.resolve()
    result = []

    def add(path):
        if private_name(path.name) or path.is_symlink() or not path.is_file() or path.suffix.lower() in GENERATED_SUFFIXES:
            return
        with path.open("rb") as stream:
            header = stream.read(8)
        if any(header.startswith(magic) for magic in COMPILED_MAGIC):
            raise ValueError(f"Compiled binary is not a public source input: {path.relative_to(root)}")
        result.append(path.relative_to(root))

    for name in sorted(ROOT_FILES):
        add(root / name)
    for name in sorted(ROOT_DIRECTORIES):
        directory = root / name
        if directory.is_symlink() or not directory.is_dir():
            continue
        for current, directories, filenames in os.walk(directory, followlinks=False):
            parent = Path(current)
            directories[:] = sorted(value for value in directories
                                    if not private_name(value) and not (parent / value).is_symlink()
                                    and Path(value).suffix.lower() not in GENERATED_DIRECTORY_SUFFIXES)
            for filename in sorted(filenames):
                add(parent / filename)
    return sorted(result, key=lambda value: value.as_posix())


def package(root, output, version, selected):
    prefix = f"Portside-{version}-source"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".portside-source-", suffix=".zip", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for relative in selected:
                entry = zipfile.ZipInfo(f"{prefix}/{relative.as_posix()}", date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                executable = relative.parts[0] == "scripts" and relative.suffix in {".sh", ".py", ".swift"}
                entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, (root / relative).read_bytes(), compresslevel=9)
        os.replace(temporary, output)
        output.chmod(0o644)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, prefix=".portside-checksum-", delete=False) as stream:
        checksum = Path(stream.name)
        stream.write(f"{digest}  {output.name}\n")
    try:
        checksum.chmod(0o644)
        os.replace(checksum, output.with_suffix(output.suffix + ".sha256"))
    finally:
        checksum.unlink(missing_ok=True)
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="Print selected public source files without creating an archive")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    selected = public_files(root)
    if args.list:
        print("\n".join(path.as_posix() for path in selected))
        return
    for required in ["Package.swift", "README.md", "LICENSE", "THIRD_PARTY.md", "packaging/macos/Info.plist"]:
        if Path(required) not in selected:
            raise ValueError(f"Missing required public source input: {required}")
    info = plistlib.loads((root / "packaging/macos/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", version):
        raise ValueError("The application version is not a safe source archive filename component.")
    output = root / "dist" / f"Portside-{version}-source.zip"
    digest = package(root, output, version, selected)
    print(f"Packaged {len(selected)} public source files: {output}")
    print(f"SHA256: {digest}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"Portside source packaging: {error}")
