#!/usr/bin/env python3
"""Fail-closed validation of localaictl backup archive members."""

from __future__ import annotations

import os
import posixpath
import shutil
import stat
import sys
import tarfile
import hashlib


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
                if has_systemd_tree(name, "system", roots):
                    fail("backup contains system manager unit configuration")
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


def systemd_tree_prefix(name: str, tree: str, roots: list[str]) -> str | None:
    for root in roots:
        prefix = root.lstrip("/").rstrip("/") + f"/.config/systemd/{tree}"
        if name == prefix or name.startswith(prefix + "/"):
            return prefix
    return None


def has_systemd_tree(name: str, tree: str, roots: list[str]) -> bool:
    return systemd_tree_prefix(name, tree, roots) is not None


def same_file_bytes(left: str, right: str) -> bool:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    left_fd = os.open(left, flags)
    try:
        right_fd = os.open(right, flags)
    except BaseException:
        os.close(left_fd)
        raise
    try:
        if not stat.S_ISREG(os.fstat(left_fd).st_mode) or not stat.S_ISREG(os.fstat(right_fd).st_mode):
            return False
        left_hash = hashlib.file_digest(os.fdopen(left_fd, "rb", closefd=False), "sha256").digest()
        right_hash = hashlib.file_digest(os.fdopen(right_fd, "rb", closefd=False), "sha256").digest()
        return left_hash == right_hash
    finally:
        os.close(left_fd)
        os.close(right_fd)


def directory_metadata_not_weaker(staged: str, installed: str) -> bool:
    staged_info = os.lstat(staged)
    installed_info = os.lstat(installed)
    if not stat.S_ISDIR(staged_info.st_mode) or not stat.S_ISDIR(installed_info.st_mode):
        return False
    if (staged_info.st_uid, staged_info.st_gid) != (installed_info.st_uid, installed_info.st_gid):
        return False
    staged_mode = stat.S_IMODE(staged_info.st_mode)
    installed_mode = stat.S_IMODE(installed_info.st_mode)
    if staged_mode & ~installed_mode:
        return False
    staged_xattrs = {
        name: os.getxattr(staged, name, follow_symlinks=False)
        for name in os.listxattr(staged, follow_symlinks=False)
    }
    installed_xattrs = {
        name: os.getxattr(installed, name, follow_symlinks=False)
        for name in os.listxattr(installed, follow_symlinks=False)
    }
    return staged_xattrs == installed_xattrs


def unit_trees(
    archive_path: str, stage: str, config: str, roots: list[str], expected_roots: list[str]
) -> list[str]:
    names = validate_archive(archive_path, config, roots)
    directories: dict[str, set[str]] = {}
    archive_prefixes = {systemd_tree_prefix(name, "user", expected_roots) for name in names}
    for index, root in enumerate(expected_roots):
        prefix = os.path.abspath(root).lstrip("/").rstrip("/") + "/.config/systemd/user"
        live_root = os.path.join("/", prefix)
        if os.path.isdir(live_root) and not os.path.islink(live_root) and prefix not in archive_prefixes:
            fail(f"backup omits an installed user service unit tree (configured root {index + 1})")
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            archive_members = {clean_member_name(info.name): info for info in archive}
        for root in roots:
            root_name = os.path.abspath(root).lstrip("/").rstrip("/")
            if root_name in archive_members and os.path.isdir(os.path.join("/", root_name)):
                if not archive_members[root_name].isdir() or not directory_metadata_not_weaker(
                    os.path.join(stage, root_name), os.path.join("/", root_name)
                ):
                    fail("backup weakens metadata on an installed persistent root")
        for name in names:
            prefix = systemd_tree_prefix(name, "user", expected_roots)
            if prefix is None:
                continue
            directories.setdefault(prefix, set()).add(name)
            info = archive_members[name]
            source = os.path.join(stage, name)
            target = os.path.join("/", name)
            root_name = member_root(name, [root.lstrip("/").rstrip("/") for root in roots])
            if root_name is None:
                fail("backup unit path is outside configured persistent roots")
            ancestor = posixpath.dirname(name)
            while ancestor == root_name or ancestor.startswith(root_name + "/"):
                staged_ancestor = os.path.join(stage, ancestor)
                installed_ancestor = os.path.join("/", ancestor)
                if ancestor not in archive_members or not archive_members[ancestor].isdir():
                    fail("backup omits directory metadata for the installed user service unit tree")
                if not directory_metadata_not_weaker(staged_ancestor, installed_ancestor):
                    fail("backup weakens metadata on an installed user service unit ancestor")
                if ancestor == root_name:
                    break
                ancestor = posixpath.dirname(ancestor)
            try:
                target_mode = os.lstat(target).st_mode
            except FileNotFoundError:
                fail("backup has a user unit absent from the installed tree")
            if info.isdir():
                if not stat.S_ISDIR(target_mode) or stat.S_ISLNK(target_mode):
                    fail("backup user unit entry type differs from the installed tree")
            elif info.isfile():
                if not stat.S_ISREG(target_mode) or not same_file_bytes(source, target):
                    fail("backup user unit file differs from the installed tree")
            elif info.issym():
                if not stat.S_ISLNK(target_mode) or os.readlink(target) != info.linkname:
                    fail("backup user unit link differs from the installed tree")
            else:
                fail("backup contains an unsupported user service unit link")
        for prefix, archived_names in directories.items():
            target_root = os.path.join("/", prefix)
            if not os.path.isdir(target_root) or os.path.islink(target_root):
                fail("backup user unit tree is absent from the installed tree")
            installed_names: set[str] = {prefix}
            for current, dirs, files in os.walk(target_root, followlinks=False):
                for entry in dirs + files:
                    path = os.path.join(current, entry)
                    relative = os.path.relpath(path, "/")
                    installed_names.add(relative)
                    if os.path.islink(path) and os.path.isdir(path):
                        # os.walk will not recurse through a linked directory.
                        continue
            if installed_names != archived_names:
                fail(f"backup user unit tree entries differ from the installed tree ({len(archived_names)} archived, {len(installed_names)} installed)")
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot verify the installed user service unit tree ({type(error).__name__})")
    return sorted(directories)


def nearest_existing_path(path: str) -> str:
    current = os.path.abspath(path)
    leaf = current
    while True:
        try:
            metadata = os.lstat(current)
            if stat.S_ISLNK(metadata.st_mode):
                if current == leaf:
                    current = os.path.dirname(current)
                    leaf = ""
                    continue
                fail("restore destination contains a symbolic link")
            return current
        except FileNotFoundError:
            pass
        parent = os.path.dirname(current)
        if parent == current:
            fail("cannot find a filesystem for a restore destination")
        current = parent


def space_check(
    archive_path: str,
    stage: str,
    collision_file: str | None = None,
    destinations: list[str] | None = None,
    *,
    staged: bool = False,
) -> None:
    archive_size = os.stat(archive_path, follow_symlinks=False).st_size
    expanded = 0
    rollback = 0
    extracted_entries = 0
    collision_entries = 0
    stage_filesystem = os.statvfs(stage)
    stage_path = nearest_existing_path(stage)

    def allocated(size: int, block_size: int) -> int:
        return max(block_size, ((size + block_size - 1) // block_size) * block_size)

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for info in archive:
                extracted_entries += 1
                if info.isfile():
                    expanded += allocated(info.size, max(1, stage_filesystem.f_frsize))
                else:
                    expanded += max(1, stage_filesystem.f_frsize)
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
                    rollback += allocated(info.st_size, max(1, stage_filesystem.f_frsize))
                else:
                    rollback += max(1, stage_filesystem.f_frsize)
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot estimate restore staging space ({type(error).__name__})")
    usage_by_filesystem: dict[tuple[int, int], dict[str, int | str]] = {}

    def filesystem_key(path: str) -> tuple[int, int]:
        probe = nearest_existing_path(path)
        filesystem = os.statvfs(probe)
        metadata = os.stat(probe, follow_symlinks=False)
        fsid = int(getattr(filesystem, "f_fsid", metadata.st_dev))
        key = (metadata.st_dev, fsid)
        if key not in usage_by_filesystem:
            usage_by_filesystem[key] = {
                "path": probe,
                "block_size": max(1, filesystem.f_frsize),
                "bytes": 0,
                "inodes": 0,
                "inodes_free": filesystem.f_favail,
                "inodes_total": filesystem.f_files,
            }
        return key

    def charge(path: str, size: int, inode_count: int = 1) -> None:
        key = filesystem_key(path)
        usage = usage_by_filesystem[key]
        block_size = int(usage["block_size"])
        usage["bytes"] = int(usage["bytes"]) + allocated(size, block_size)
        usage["inodes"] = int(usage["inodes"]) + inode_count

    stage_key = filesystem_key(stage_path)
    stage_usage = usage_by_filesystem[stage_key]
    if staged:
        # The archive copy and extracted tree already consume staging space.
        # Only the rollback snapshot remains to be written in this phase.
        stage_usage["bytes"] = int(stage_usage["bytes"]) + rollback
        stage_usage["inodes"] = int(stage_usage["inodes"]) + int(collision_entries > 0)
    else:
        stage_usage["bytes"] = int(stage_usage["bytes"]) + archive_size + expanded + rollback
        stage_usage["inodes"] = int(stage_usage["inodes"]) + extracted_entries + collision_entries

    if destinations:
        configured = [os.path.abspath(path).lstrip("/").rstrip("/") for path in destinations]
        if any(not path for path in configured) or len(set(configured)) != len(configured):
            fail("restore destination paths are invalid")

        def destination_root(name: str) -> str | None:
            matches = [root for root in configured if name == root or name.startswith(root + "/")]
            return max(matches, key=len) if matches else None

        destination_nodes: dict[str, int] = {}

        def charge_tree(name: str, size: int | None) -> None:
            root = destination_root(name)
            if root is None:
                fail("cannot estimate an unconfigured restore destination")
            current = name
            destination_nodes[current] = 0 if size is None else size
            while current != root:
                parent = posixpath.dirname(current)
                if not parent or (parent != root and not parent.startswith(root + "/")):
                    fail("restore archive path is outside its configured destination")
                # Account for implicit parent directories too; charging existing
                # directories is conservative and covers tar-created ancestors.
                destination_nodes.setdefault(parent, 0)
                current = parent

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
                charge_tree(name, size)
            for name, size in destination_nodes.items():
                charge("/" + name, size)
            if collision_file:
                for encoded in open(collision_file, "rb").read().split(b"\0"):
                    if not encoded:
                        continue
                    name = clean_member_name(os.fsdecode(encoded))
                    try:
                        info = os.lstat(os.path.join("/", name))
                    except FileNotFoundError:
                        continue
                    charge("/" + name, info.st_size if stat.S_ISREG(info.st_mode) else 0)
        except (OSError, tarfile.TarError) as error:
            fail(f"cannot estimate destination filesystem requirements ({type(error).__name__})")

    # Stage and destination requirements share one ledger so space and inode
    # needs are summed when they land on the same filesystem or subvolume.
    for usage in usage_by_filesystem.values():
        path = str(usage["path"])
        free = shutil.disk_usage(path).free
        required = int(usage["bytes"]) + 64 * 1024 * 1024
        if free < required:
            fail("insufficient free disk space for restore and rollback on a filesystem")
        if int(usage["inodes_total"]) and int(usage["inodes_free"]) < int(usage["inodes"]) + 16:
            fail("insufficient free inodes for restore and rollback on a filesystem")


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
        staged = "--staged" in rest
        if staged:
            rest.remove("--staged")
        collision_file = rest[0] if rest and rest[0] != "--destinations" else None
        if collision_file:
            rest = rest[1:]
        destinations = None
        if rest:
            if rest[0] != "--destinations" or len(rest) == 1:
                raise SystemExit(2)
            destinations = rest[1:]
        space_check(sys.argv[2], sys.argv[3], collision_file, destinations, staged=staged)
        return
    if len(sys.argv) < 4 or sys.argv[1] not in {"validate", "validate-created", "members0", "collisions0", "destinations", "skip-links0", "unit-trees0", "rollback-new", "copy-source"}:
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
    roots = rest[:-3] if mode == "unit-trees0" else rest[:-1] if mode in {"destinations", "skip-links0"} else rest
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
    if mode == "unit-trees0":
        if len(rest) < 3:
            raise SystemExit(2)
        for name in unit_trees(archive, rest[-3], config, roots, rest[-2:]):
            sys.stdout.buffer.write(os.fsencode(name) + b"\0")
    if mode in {"members0", "collisions0"}:
        write_names(names, mode, config, roots)


if __name__ == "__main__":
    main()
