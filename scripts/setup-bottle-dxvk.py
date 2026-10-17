#!/usr/bin/env python3
"""Install/remove a pinned DXVK component in one owned, stopped Portside bottle."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse
import uuid

OWNER = "app.portside.mac"
VERSION = "1.10.3-portside1"
COMMIT = "8f1e28deed3ad30802f7e1bdff428ec14e6e7817"
FILES = {
    "x32/d3d10core.dll": "01e2b0890d25decbfe67babd74515944b355b85fe1881dfbad564cd6e5aadffc",
    "x32/d3d11.dll": "f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0",
    "x64/d3d10core.dll": "e7c1a633fefcebae3803f015b5e4f267ace447c6517bef7b3e1d35f16a50363a",
    "x64/d3d11.dll": "0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4",
}
OVERRIDES = {"d3d10core": "native,builtin", "d3d11": "native,builtin", "dxgi": "builtin"}
REGISTRY_KEY = r"HKCU\Software\Wine\DllOverrides"


class SetupError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise SetupError(message)


def regular(path):
    return path.exists() and stat.S_ISREG(path.lstat().st_mode)


def no_link(path):
    require(not path.is_symlink(), f"Refusing symbolic link for managed data: {path}")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


def read_json(path):
    no_link(path)
    require(regular(path), f"Expected a regular JSON file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path, value):
    no_link(path)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    os.replace(temporary, path)


def managed_bottle(home, bottle_id):
    home = Path(os.path.abspath(home.expanduser()))
    bottles = home / "Bottles"
    for path in (home, bottles):
        no_link(path)
        require(path.is_dir(), f"Managed directory is missing: {path}")
    catalog = read_json(home / "library.json")
    require(catalog.get("schemaVersion") == 1, "Unsupported Portside catalog schema.")
    entries = catalog.get("bottles", [])
    ids = [entry.get("id") for entry in entries]
    require(len(ids) == len(set(ids)), "The catalog contains duplicate bottle IDs.")
    require(all(entry.get("directoryName") == entry.get("id") == str(uuid.UUID(entry["id"])).upper()
                for entry in entries), "The catalog contains unsafe bottle directory names.")
    matches = [entry for entry in entries if entry["id"] == bottle_id]
    require(len(matches) == 1, "Bottle UUID is not present in this Portside catalog.")
    bottle = matches[0]
    require(bottle.get("initialized") is True, "Initialize this bottle in Portside before setting up DXVK.")
    prefix = bottles / bottle_id
    no_link(prefix)
    require(prefix.is_dir() and prefix.resolve().parent == bottles.resolve(), "Bottle points outside managed Bottles.")
    marker = read_json(prefix / ".portside-bottle.json")
    require(marker.get("owner") == OWNER and marker.get("bottleID") == bottle_id,
            "Bottle ownership marker is missing or does not match. No bottle files were changed.")
    for relative in ("drive_c", "drive_c/windows", "drive_c/windows/system32", "drive_c/windows/syswow64"):
        directory = prefix / relative
        no_link(directory)
        require(directory.is_dir() and prefix.resolve() in directory.resolve().parents,
                f"Unsafe or missing Windows system directory: {directory}")
    runtime = bottle.get("runtime", {})
    url = urlparse(runtime.get("wineURL", ""))
    require(url.scheme == "file" and url.netloc in ("", "localhost") and not url.query and not url.fragment,
            "Bottle runtime must be a local file URL from the Portside catalog.")
    wine = Path(unquote(url.path))
    server = wine.parent / "wineserver"
    require(wine.is_file() and os.access(wine, os.X_OK) and server.is_file() and os.access(server, os.X_OK),
            f"Wine and wineserver must both be executable in {wine.parent}. Select a complete runtime in Portside.")
    return prefix, bottle, wine, server


def validate_component(directory):
    directory = directory.expanduser().resolve(strict=True)
    manifest = read_json(directory / "component.json")
    require(manifest.get("schemaVersion") == 1 and manifest.get("id") == "dxvk-macos"
            and manifest.get("version") == VERSION and manifest.get("upstreamCommit") == COMMIT,
            "Component ID, version, or source commit is not the supported pinned DXVK build.")
    require(manifest.get("files") == FILES, "Component DLL hashes do not match the pinned Portside build.")
    for name, expected in FILES.items():
        arch = directory / name.split("/")[0]
        no_link(arch)
        source = directory / name
        no_link(source)
        require(regular(source) and digest(source) == expected, f"Component checksum mismatch: {source}")
        with source.open("rb") as stream:
            header = stream.read(64)
            require(len(header) == 64 and header[:2] == b"MZ", f"Invalid Windows DLL: {source}")
            stream.seek(struct.unpack_from("<I", header, 60)[0])
            pe = stream.read(24)
        expected_machine = 0x14c if name.startswith("x32/") else 0x8664
        require(len(pe) == 24 and pe[:4] == b"PE\0\0" and struct.unpack_from("<H", pe, 4)[0] == expected_machine
                and struct.unpack_from("<H", pe, 22)[0] & 0x2000, f"Wrong PE architecture or non-DLL file: {source}")
    return directory, manifest


class Installer:
    def __init__(self, prefix, bottle, wine, server):
        self.prefix, self.bottle, self.wine, self.server = prefix, bottle, wine, server
        self.base = prefix / ".portside-components"
        self.directory = self.base / "dxvk-macos"
        self.state_path = self.directory / "state.json"
        self.backups = self.directory / "originals"
        self.log = None
        self.lock_held = False
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.upper().startswith(("WINE", "DYLD_", "CX_", "LC_"))
                            and key not in ("LD_PRELOAD", "CFProcessPath", "__CFBundleIdentifier", "PORTSIDE_WINE_UI_BUNDLE", "LANGUAGE")}
        self.environment.update(WINEPREFIX=str(prefix), WINEARCH="win64", WINEDEBUG="-all,err+all",
                                MVK_CONFIG_LOG_LEVEL="0", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
                                PATH=str(wine.parent) + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")

    def record(self, message):
        if self.log:
            self.log.write(datetime.now(timezone.utc).isoformat() + " " + message + "\n")
            self.log.flush()

    def command(self, executable, arguments, timeout=30, allowed=(0,)):
        self.record("command " + json.dumps([str(executable), *arguments], ensure_ascii=False))
        try:
            # Wine background services can inherit stdout after the direct reg
            # process exits. A regular file avoids waiting for their pipe EOF.
            with tempfile.TemporaryFile() as output:
                result = subprocess.run([str(executable), *arguments], env=self.environment, stdin=subprocess.DEVNULL,
                                        stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
                output.seek(0, os.SEEK_END)
                output.seek(max(0, output.tell() - 65_536))
                data = output.read(65_536)
        except subprocess.TimeoutExpired as error:
            # subprocess.run terminates only this helper command, never a bottle server.
            self.record("command timed out")
            raise SetupError(f"Command timed out after {timeout}s: {executable.name} {' '.join(arguments)}") from error
        text = data.decode("utf-8", errors="replace").replace("\r\n", "\n").strip()
        self.record(f"exit {result.returncode}: {text}")
        require(result.returncode in allowed, f"{executable.name} exited {result.returncode}: {text}")
        return result.returncode, text

    def idle(self, timeout):
        try:
            self.command(self.server, ["-w"], timeout=timeout)
        except SetupError as error:
            raise SetupError("The bottle is running or Wine shutdown could not be confirmed. Stop this bottle in Portside, "
                             "close the frontend to prevent a simultaneous launch, and retry. No stop request was sent. " + str(error)) from error

    def start(self):
        # Check before creating any component metadata or changing bottle files.
        self.idle(1.5)
        for directory in (self.base, self.directory, self.backups):
            no_link(directory)
            directory.mkdir(exist_ok=True)
            require(directory.is_dir(), f"Expected a managed component directory: {directory}")
        self.lock = self.directory / "operation.lock"
        no_link(self.lock)
        try:
            self.lock.mkdir()
            self.lock_held = True
        except FileExistsError as error:
            raise SetupError(f"Another setup operation holds {self.lock}. If it was interrupted, verify no setup helper is running before removing this lock.") from error
        log_path = self.directory / "operations.log"
        no_link(log_path)
        self.log = log_path.open("a", encoding="utf-8")

    def close(self):
        if self.log:
            self.log.close()
        if self.lock_held and self.lock.is_dir():
            self.lock.rmdir()

    def destination(self, name):
        arch, filename = name.split("/")
        return self.prefix / "drive_c/windows" / ("syswow64" if arch == "x32" else "system32") / filename

    def backup_path(self, name):
        arch, filename = name.split("/")
        return self.backups / (arch + "-" + filename)

    def describe(self, path):
        if path.is_symlink():
            return {"kind": "symlink", "target": os.readlink(path)}
        if not path.exists():
            return {"kind": "absent"}
        require(regular(path), f"Refusing to replace a non-file DLL entry: {path}")
        return {"kind": "file", "sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)}

    def overrides(self):
        values = {}
        for name in OVERRIDES:
            code, output = self.command(self.wine, ["reg", "query", REGISTRY_KEY, "/v", name], allowed=(0, 1))
            if code == 1:
                require(re.search(r"unable to find|cannot find|not found|does not exist|specified registry key", output, re.I),
                        f"Could not determine whether registry override {name} exists: {output}")
                values[name] = None
            else:
                match = re.search(r"^\s*" + re.escape(name) + r"\s+REG_SZ(?:\s+(.*))?$", output, re.M | re.I)
                require(match is not None, f"Override {name} has an unsupported registry type or output format; its value was preserved.")
                values[name] = match.group(1) or ""
        return values

    def write_overrides(self, values):
        for name in OVERRIDES:
            value = values[name]
            if value is None:
                code, output = self.command(self.wine, ["reg", "delete", REGISTRY_KEY, "/v", name, "/f"], allowed=(0, 1))
                require(code == 0 or re.search(r"unable to find|cannot find|not found|does not exist|specified registry key", output, re.I),
                        f"Could not remove override {name}: {output}")
            else:
                self.command(self.wine, ["reg", "add", REGISTRY_KEY, "/v", name, "/t", "REG_SZ", "/d", value, "/f"])

    def load_state(self):
        if not self.state_path.exists() and not self.state_path.is_symlink():
            return None
        state = read_json(self.state_path)
        require(state.get("schemaVersion") == 1 and state.get("owner") == OWNER
                and state.get("bottleID") == self.bottle["id"] and state.get("componentVersion") == VERSION,
                "The existing component state does not belong to this bottle/component version.")
        require(set(state.get("originalFiles", {})) == set(FILES)
                and set(state.get("originalOverrides", {})) == set(OVERRIDES), "Incomplete original component backups; files were preserved.")
        for name, entry in state["originalFiles"].items():
            require(entry.get("kind") in ("file", "symlink", "absent"), "Invalid component backup type.")
            if entry["kind"] == "file":
                backup = self.backup_path(name)
                no_link(backup)
                require(regular(backup) and digest(backup) == entry.get("sha256"), f"Original DLL backup is missing or damaged: {backup}")
            if entry["kind"] == "symlink":
                require(isinstance(entry.get("target"), str) and "\0" not in entry["target"], "Invalid saved symlink target.")
        require(all(value is None or isinstance(value, str) for value in state["originalOverrides"].values()), "Invalid saved registry overrides.")
        return state

    def snapshot(self, manifest):
        originals = {}
        for name in FILES:
            path = self.destination(name)
            originals[name] = self.describe(path)
            if originals[name]["kind"] == "file":
                backup = self.backup_path(name)
                no_link(backup)
                if backup.exists():
                    require(regular(backup) and digest(backup) == originals[name]["sha256"], f"A different first backup already exists: {backup}")
                else:
                    shutil.copyfile(path, backup)
        previous = self.overrides()
        self.idle(15)
        state = {"schemaVersion": 1, "owner": OWNER, "bottleID": self.bottle["id"], "componentVersion": VERSION,
                 "status": "prepared", "originalFiles": originals, "originalOverrides": previous,
                 "runtime": self.bottle["runtime"], "component": manifest,
                 "createdAt": datetime.now(timezone.utc).isoformat()}
        save_json(self.state_path, state)
        return state

    def restore_files(self, state):
        for name, entry in state["originalFiles"].items():
            destination = self.destination(name)
            self.record("restore " + str(destination))
            if entry["kind"] == "absent":
                require(not destination.exists() or regular(destination) or destination.is_symlink(), f"Refusing non-file DLL entry: {destination}")
                destination.unlink(missing_ok=True)
            elif entry["kind"] == "symlink":
                temporary = destination.with_name(".portside-restore-" + str(uuid.uuid4()))
                try:
                    temporary.symlink_to(entry["target"])
                    os.replace(temporary, destination)
                finally:
                    temporary.unlink(missing_ok=True)
            else:
                self.replace_file(self.backup_path(name), destination)
                os.chmod(destination, entry["mode"], follow_symlinks=False)

    def replace_file(self, source, destination):
        # Replacing the directory entry unlinks any Wine builtin symlink without
        # following it or writing through it into the shared Wine runtime.
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".portside-dll-", delete=False) as stream:
            temporary = Path(stream.name)
        try:
            shutil.copyfile(source, temporary)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)

    def install(self, component, manifest):
        state = self.load_state() or self.snapshot(manifest)
        if state["status"] == "installed":
            require(all(self.describe(self.destination(name)).get("sha256") == value for name, value in FILES.items())
                    and self.overrides() == OVERRIDES, "An installed DLL or override changed. Inspect the preserved component state before replacing it.")
            self.record("already installed")
            print(f"DXVK {VERSION} is already installed in {self.bottle['name']}.")
            return
        require(state["status"] in ("prepared", "removed", "rolled-back"), "A previous setup needs manual recovery; inspect state.json and operations.log.")
        require(all(self.describe(self.destination(name)) == original for name, original in state["originalFiles"].items())
                and self.overrides() == state["originalOverrides"], "The bottle changed since its first snapshot. Original backups were preserved; inspect them before retrying.")
        self.idle(15)
        state["status"] = "installing"
        save_json(self.state_path, state)
        try:
            for name in FILES:
                self.record("install " + name)
                self.replace_file(component / name, self.destination(name))
                require(digest(self.destination(name)) == FILES[name], "Copied DLL did not match its pinned checksum.")
            self.write_overrides(OVERRIDES)
            require(self.overrides() == OVERRIDES, "Wine did not retain the requested DLL overrides.")
            state["status"] = "installed"
            state["installedAt"] = datetime.now(timezone.utc).isoformat()
            save_json(self.state_path, state)
        except BaseException:
            try:
                self.idle(15)
                self.restore_files(state)
                self.write_overrides(state["originalOverrides"])
                state["status"] = "rolled-back"
                save_json(self.state_path, state)
                self.record("installation failure rolled back")
            except BaseException as rollback_error:
                state["status"] = "recovery-needed"
                state["recoveryError"] = str(rollback_error)
                save_json(self.state_path, state)
                self.record("rollback needs recovery: " + str(rollback_error))
            raise
        print(f"Installed DXVK {VERSION} in {self.bottle['name']}. First backups and log: {self.directory}")

    def remove(self):
        state = self.load_state()
        require(state is not None, "This bottle has no DXVK setup record to restore.")
        if state["status"] in ("removed", "rolled-back"):
            print("DXVK was already removed; original backups remain preserved.")
            return
        require(state["status"] in ("installed", "installing", "removing", "recovery-needed", "prepared"),
                "Unrecognized setup state; inspect state.json and operations.log before removal.")
        # Also recover an interrupted install/remove when each entry is either
        # its original value or the exact component value. Preserve later edits.
        current_overrides = self.overrides()
        require(all(self.describe(self.destination(name)) == original
                    or self.describe(self.destination(name)).get("sha256") == FILES[name]
                    for name, original in state["originalFiles"].items())
                and all(current_overrides[name] in (state["originalOverrides"][name], OVERRIDES[name])
                        for name in OVERRIDES),
                "A managed DLL or override changed after setup. Removal refused to avoid overwriting later changes.")
        self.idle(15)
        state["status"] = "removing"
        save_json(self.state_path, state)
        try:
            self.restore_files(state)
            self.write_overrides(state["originalOverrides"])
            require(self.overrides() == state["originalOverrides"], "Wine did not retain the restored DLL overrides.")
        except BaseException as error:
            state["status"] = "recovery-needed"
            state["recoveryError"] = str(error)
            save_json(self.state_path, state)
            raise
        state["status"] = "removed"
        state["removedAt"] = datetime.now(timezone.utc).isoformat()
        save_json(self.state_path, state)
        self.record("original files and registry overrides restored")
        print(f"Removed DXVK from {self.bottle['name']}; first backups remain at {self.directory}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bottle_uuid", help="UUID of one existing, initialized Portside bottle")
    parser.add_argument("--component-dir", type=Path, help="Explicit built component directory (required for installation)")
    parser.add_argument("--home", type=Path, default=Path.home() / "Library/Application Support/Portside",
                        help="Portside Application Support root (for isolated fixtures/custom catalogs)")
    parser.add_argument("--remove", action="store_true", help="Restore first DLL backups and prior registry overrides")
    arguments = parser.parse_args()
    installer = None
    try:
        bottle_id = str(uuid.UUID(arguments.bottle_uuid)).upper()
        prefix, bottle, wine, server = managed_bottle(arguments.home, bottle_id)
        if not arguments.remove:
            require(arguments.component_dir is not None, "--component-dir is required for installation.")
            component, manifest = validate_component(arguments.component_dir)
        installer = Installer(prefix, bottle, wine, server)
        installer.start()
        installer.record(("remove" if arguments.remove else "install") + " component " + VERSION)
        if arguments.remove:
            installer.remove()
        else:
            installer.install(component, manifest)
        return 0
    except (SetupError, OSError, ValueError, KeyError, TypeError) as error:
        if installer:
            installer.record("error: " + str(error))
        print("Portside DXVK setup: " + str(error), file=sys.stderr)
        return 1
    finally:
        if installer:
            installer.close()


if __name__ == "__main__":
    sys.exit(main())
