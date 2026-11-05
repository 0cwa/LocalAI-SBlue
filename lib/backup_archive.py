#!/usr/bin/env python3
"""Fail-closed validation of localaictl backup archive members."""

from __future__ import annotations

import os
import posixpath
import shutil
import stat
import sys
import tarfile


def fail(message: str) -> None:
    print(f"localaictl: {message}", file=sys.stderr)
    raise SystemExit(1)


def clean_member_name(name: str) -> str:
    if not name or name.startswith("/") or "\x00" in name or "\n" in name or "\r" in name:
        fail("backup contains an unsafe member name")
    parts = name.rstrip("/").split("/")
    if any(part in ("", ".", "..") for part in parts):
        fail("backup contains a traversal path")
    return "/".join(parts)


def member_root(name: str, roots: list[str]) -> str | None:
    matches = [root for root in roots if name == root or name.startswith(root + "/")]
    return max(matches, key=len) if matches else None


def validate_archive(archive: str, config: str, roots: list[str], *, require_root_config: bool = True) -> list[str]:
    config_name = config.lstrip("/")
    prefixes = [p.lstrip("/").rstrip("/") for p in roots]
    if any(not p for p in prefixes) or len(set(prefixes)) != len(prefixes):
        fail("configured backup paths must be distinct absolute paths")
    members: dict[str, tarfile.TarInfo] = {}
    try:
        fd = os.open(archive, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            fail("backup must be a regular non-linked file")
        with os.fdopen(fd, "rb") as stream, tarfile.open(fileobj=stream, mode="r:gz") as source:
            for info in source:
                name = clean_member_name(info.name)
                if name in members:
                    fail("backup contains duplicate member names")
                if name != "metadata" and name != config_name and member_root(name, prefixes) is None:
                    fail("backup contains a path outside configured LocalAI paths")
                if not (info.isfile() or info.isdir() or info.issym() or info.islnk()):
                    fail("backup contains an unsupported special file")
                if info.mode & 0o6000:
                    fail("backup contains setuid or setgid permission bits")
                if any(key.lower().endswith("security.capability") and value for key, value in info.pax_headers.items()):
                    fail("backup contains a file capability xattr")
                if name == config_name:
                    expected_uid = 0 if require_root_config else os.stat(config, follow_symlinks=False).st_uid
                    if not info.isfile() or info.uid != expected_uid or info.mode & 0o022:
                        ownership = "root-owned" if require_root_config else "owned by its source file owner"
                        fail(f"backup configuration member must be a {ownership} regular file without group or world write permission")
                if name in prefixes and not info.isdir():
                    fail("configured persistent path must be archived as a directory")
                members[name] = info
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot read backup archive ({type(error).__name__})")

    for name, info in members.items():
        parent = posixpath.dirname(name)
        while parent:
            if parent in members and not members[parent].isdir():
                fail("backup contains a member nested below a non-directory entry")
            parent = posixpath.dirname(parent)
        if info.issym():
            link = info.linkname
            if "\x00" in link or "\n" in link or "\r" in link:
                fail("backup contains an unsafe symbolic link")
            resolved = posixpath.normpath(link.lstrip("/")) if link.startswith("/") else posixpath.normpath(posixpath.join(posixpath.dirname(name), link))
            if resolved == ".." or resolved.startswith("../"):
                fail("backup contains a symbolic link escaping its archived tree")
            if member_root(name, prefixes) != member_root(resolved, prefixes):
                fail("backup contains a symbolic link crossing configured persistent paths")
        elif info.islnk():
            target = clean_member_name(info.linkname)
            root = member_root(name, prefixes)
            target_root = member_root(target, prefixes)
            if target not in members or not members[target].isfile() or root != target_root:
                fail("backup contains an invalid hard link")
    if "metadata" not in members or not members["metadata"].isfile():
        fail("backup metadata is missing")
    return list(members)


def copy_source(source: str, destination: str) -> None:
    fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        fail("restore source must be a regular non-linked file")
    with os.fdopen(fd, "rb") as input_file, open(destination, "xb") as output_file:
        shutil.copyfileobj(input_file, output_file)
    os.chmod(destination, 0o600)


def stage_check(stage: str) -> None:
    target = os.path.realpath(stage)
    best_mount = "/"
    best_type = ""
    try:
        with open("/proc/self/mountinfo", encoding="utf-8") as mounts:
            for line in mounts:
                fields = line.rstrip("\n").split()
                separator = fields.index("-")
                mountpoint = fields[4].replace("\\040", " ").replace("\\011", "\t").replace("\\134", "\\")
                if (target == mountpoint or target.startswith(mountpoint.rstrip("/") + "/")) and len(mountpoint) >= len(best_mount):
                    best_mount = mountpoint
                    best_type = fields[separator + 1]
    except (OSError, ValueError):
        fail("cannot verify restore staging filesystem")
    if best_type in {"tmpfs", "ramfs"}:
        fail("restore staging filesystem is memory-backed")


def nearest_existing_path(path: str) -> str:
    current = os.path.abspath(path)
    while not os.path.exists(current):
        parent = os.path.dirname(current)
        if parent == current:
            fail("cannot find a filesystem for a restore destination")
        current = parent
    return current


def space_check(
    archive_path: str,
    stage: str,
    collision_file: str | None = None,
    destinations: list[str] | None = None,
) -> None:
    archive_size = os.stat(archive_path, follow_symlinks=False).st_size
    expanded = 0
    rollback = 0
    extracted_entries = 0
    collision_entries = 0
    stage_filesystem = os.statvfs(stage)
    block_size = stage_filesystem.f_frsize

    def allocated(size: int) -> int:
        return max(block_size, ((size + block_size - 1) // block_size) * block_size)

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for info in archive:
                extracted_entries += 1
                if info.isfile():
                    expanded += allocated(info.size)
                else:
                    expanded += block_size
        if collision_file:
            for encoded in open(collision_file, "rb").read().split(b"\0"):
                if not encoded:
                    continue
                collision_entries += 1
                try:
                    info = os.lstat(os.path.join("/", os.fsdecode(encoded)))
                except FileNotFoundError:
                    continue
                if stat.S_ISREG(info.st_mode):
                    rollback += allocated(info.st_size)
                else:
                    rollback += block_size
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot estimate restore staging space ({type(error).__name__})")
    required = archive_size + expanded + rollback + 64 * 1024 * 1024
    available = shutil.disk_usage(stage).free
    if available < required:
        fail("insufficient free disk space for archive extraction and rollback")
    if stage_filesystem.f_files and stage_filesystem.f_favail < extracted_entries + collision_entries + 16:
        fail("insufficient free inodes for archive extraction and rollback")

    if not destinations:
        return

    configured = [os.path.abspath(path).lstrip("/").rstrip("/") for path in destinations]
    if any(not path for path in configured) or len(set(configured)) != len(configured):
        fail("restore destination paths are invalid")
    destination_usage: dict[tuple[int, int], dict[str, int | str]] = {}

    def destination_filesystem(root: str) -> tuple[int, int]:
        probe = nearest_existing_path("/" + root)
        filesystem = os.statvfs(probe)
        # f_fsid distinguishes mounts sharing a device number. Fall back to st_dev
        # only on platforms whose statvfs result omits it.
        try:
            device = os.stat(probe).st_dev
        except OSError as error:
            fail(f"cannot inspect a restore destination filesystem ({type(error).__name__})")
        fsid = int(getattr(filesystem, "f_fsid", device))
        key = (device, fsid)
        if key not in destination_usage:
            destination_usage[key] = {
                "path": probe,
                "block_size": max(1, filesystem.f_frsize),
                "bytes": 0,
                "inodes": 0,
            }
        return key

    def destination_root(name: str) -> str | None:
        matches = [root for root in configured if name == root or name.startswith(root + "/")]
        return max(matches, key=len) if matches else None

    def charge(name: str, size: int | None) -> None:
        root = destination_root(name)
        if root is None:
            return
        key = destination_filesystem(root)
        usage = destination_usage[key]
        per_fs_block = int(usage["block_size"])
        amount = per_fs_block if size is None else max(per_fs_block, ((size + per_fs_block - 1) // per_fs_block) * per_fs_block)
        usage["bytes"] = int(usage["bytes"]) + amount
        usage["inodes"] = int(usage["inodes"]) + 1

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            archive_members = {clean_member_name(info.name): info for info in archive}
        for name, info in archive_members.items():
            if name == "metadata":
                continue
            size = info.size if info.isfile() else None
            if info.islnk():
                target = archive_members.get(clean_member_name(info.linkname))
                size = target.size if target is not None and target.isfile() else None
            charge(name, size)
        if collision_file:
            for encoded in open(collision_file, "rb").read().split(b"\0"):
                if not encoded:
                    continue
                name = clean_member_name(os.fsdecode(encoded))
                try:
                    info = os.lstat(os.path.join("/", name))
                except FileNotFoundError:
                    continue
                charge(name, info.st_size if stat.S_ISREG(info.st_mode) else None)
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot estimate destination filesystem requirements ({type(error).__name__})")

    for key, usage in destination_usage.items():
        path = str(usage["path"])
        filesystem = os.statvfs(path)
        free = shutil.disk_usage(path).free
        required = int(usage["bytes"]) + 64 * 1024 * 1024
        if free < required:
            fail("insufficient free disk space on a restore destination filesystem")
        if filesystem.f_files and filesystem.f_favail < int(usage["inodes"]) + 16:
            fail("insufficient free inodes on a restore destination filesystem")


def validate_destinations(names: list[str], stage: str, config: str, roots: list[str]) -> list[str]:
    roots = [os.path.abspath(p) for p in [config, *roots]]
    for root in roots:
        if os.path.islink(root):
            fail("refusing to restore through a linked configured path")
        current = os.path.dirname(root)
        while current != os.path.dirname(current):
            if os.path.islink(current):
                fail("refusing to restore through a linked parent path")
            current = os.path.dirname(current)
    with tarfile.open(os.path.join(stage, "input.tar.gz"), "r:gz") as archive:
        archive_members = {clean_member_name(info.name): info for info in archive}
    identical_links: list[str] = []
    for name in names:
        if name == "metadata":
            continue
        candidate = os.path.join("/", name)
        relative = os.path.relpath(candidate, "/")
        staged = os.path.join(stage, relative)
        if os.path.islink(staged) and any(staged == os.path.join(stage, root.lstrip("/")) for root in roots[1:]):
            fail("backup persistent root must be a directory, not a symbolic link")
        current = candidate
        while current != "/":
            if os.path.islink(current):
                if current == candidate:
                    info = archive_members.get(name)
                    if info is not None and info.issym() and os.readlink(current) == info.linkname:
                        identical_links.append(name)
                        break
                fail("restore path contains a symbolic link that does not exactly match the archive")
            current = os.path.dirname(current)
    return identical_links


def write_names(names: list[str], mode: str, config: str, roots: list[str]) -> None:
    selected: set[str] = set()
    for name in names:
        if name == "metadata":
            continue
        selected.add(name)
        if mode == "collisions0":
            for root in [os.path.abspath(config), *(os.path.abspath(p) for p in roots)]:
                root_name = root.lstrip("/").rstrip("/")
                if name == root_name or name.startswith(root_name + "/"):
                    parent = posixpath.dirname(name)
                    while parent == root_name or parent.startswith(root_name + "/"):
                        selected.add(parent)
                        if parent == root_name:
                            break
                        parent = posixpath.dirname(parent)
                    break
    for name in sorted(selected):
        if mode == "collisions0" and not os.path.lexists(os.path.join("/", name)):
            continue
        sys.stdout.buffer.write(os.fsencode(name) + b"\0")


def rollback_new(member_file: str, collision_file: str, config: str, roots: list[str]) -> int:
    members = open(member_file, "rb").read().split(b"\0")
    collisions = set(open(collision_file, "rb").read().split(b"\0"))
    roots = [p.lstrip("/").rstrip("/") for p in roots]
    config_name = config.lstrip("/")
    status = 0
    for encoded in reversed(members):
        if not encoded or encoded == b"metadata" or encoded in collisions:
            continue
        name = os.fsdecode(encoded)
        if name != config_name and member_root(name, roots) is None:
            continue
        path = os.path.join("/", name)
        try:
            if os.path.islink(path) or not os.path.isdir(path):
                os.unlink(path)
            else:
                os.rmdir(path)
        except FileNotFoundError:
            pass
        except OSError:
            # A concurrent or unrelated entry makes the directory non-empty;
            # preserve it and leave rollback best-effort rather than recurse.
            status = 1
    parents: set[str] = set()
    for encoded in members:
        if not encoded or encoded == b"metadata" or encoded in collisions:
            continue
        parent = os.path.dirname(os.path.join("/", os.fsdecode(encoded)))
        while any(parent == root or parent.startswith(root + "/") for root in roots):
            parent_name = parent.lstrip("/")
            if parent_name in collisions:
                break
            parents.add(parent)
            parent = os.path.dirname(parent)
    for path in sorted(parents, key=lambda entry: entry.count("/"), reverse=True):
        try:
            os.rmdir(path)
        except FileNotFoundError:
            pass
        except OSError:
            status = 1
    return status


def main() -> None:
    if sys.argv[1:2] == ["stage-check"]:
        if len(sys.argv) != 3:
            raise SystemExit(2)
        stage_check(sys.argv[2])
        return
    if sys.argv[1:2] == ["space-check"]:
        if len(sys.argv) < 4:
            raise SystemExit(2)
        rest = sys.argv[4:]
        collision_file = rest[0] if rest and rest[0] != "--destinations" else None
        if collision_file:
            rest = rest[1:]
        destinations = None
        if rest:
            if rest[0] != "--destinations" or len(rest) == 1:
                raise SystemExit(2)
            destinations = rest[1:]
        space_check(sys.argv[2], sys.argv[3], collision_file, destinations)
        return
    if len(sys.argv) < 4 or sys.argv[1] not in {"validate", "validate-created", "members0", "collisions0", "destinations", "skip-links0", "rollback-new", "copy-source"}:
        raise SystemExit(2)
    mode, archive, config = sys.argv[1:4]
    rest = sys.argv[4:]
    if mode == "copy-source":
        if len(rest) < 1:
            raise SystemExit(2)
        copy_source(archive, rest[-1])
        return
    if mode == "rollback-new":
        if len(rest) < 3:
            raise SystemExit(2)
        raise SystemExit(rollback_new(rest[-2], rest[-1], config, rest[:-2]))
    roots = rest[:-1] if mode in {"destinations", "skip-links0"} else rest
    names = validate_archive(archive, config, roots, require_root_config=mode != "validate-created" or os.geteuid() == 0)
    if mode == "destinations":
        if not rest:
            raise SystemExit(2)
        validate_destinations(names, rest[-1], config, roots)
    if mode == "skip-links0":
        if not rest:
            raise SystemExit(2)
        for name in validate_destinations(names, rest[-1], config, roots):
            sys.stdout.buffer.write(os.fsencode(name) + b"\0")
    if mode in {"members0", "collisions0"}:
        write_names(names, mode, config, roots)


if __name__ == "__main__":
    main()
