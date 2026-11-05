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


def validate_archive(archive: str, config: str, state: str, tls: str) -> list[str]:
    prefixes = [p.lstrip("/").rstrip("/") for p in (config, state, tls)]
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
                if name != "metadata" and not any(name == p or name.startswith(p + "/") for p in prefixes):
                    fail("backup contains a path outside configured LocalAI paths")
                if not (info.isfile() or info.isdir() or info.issym() or info.islnk()):
                    fail("backup contains an unsupported special file")
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
            if not any(resolved == p or resolved.startswith(p + "/") for p in prefixes):
                fail("backup contains a symbolic link outside configured LocalAI paths")
        elif info.islnk():
            target = clean_member_name(info.linkname)
            root = next((p for p in prefixes if name == p or name.startswith(p + "/")), None)
            target_root = next((p for p in prefixes if target == p or target.startswith(p + "/")), None)
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


def validate_destinations(names: list[str], stage: str, config: str, state: str, tls: str) -> list[str]:
    roots = [os.path.abspath(p) for p in (config, state, tls)]
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
        if os.path.islink(staged) and any(staged == os.path.join(stage, root.lstrip("/")) for root in (state, tls)):
            fail("backup state root must be a directory, not a symbolic link")
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


def write_names(names: list[str], mode: str) -> None:
    selected: set[str] = set()
    for name in names:
        if name == "metadata":
            continue
        selected.add(name)
        if mode == "collisions0":
            for root in (os.path.dirname(os.path.abspath(sys.argv[3])), os.path.abspath(sys.argv[4]), os.path.abspath(sys.argv[5])):
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


def rollback_new(member_file: str, collision_file: str, config: str, state: str, tls: str) -> int:
    members = open(member_file, "rb").read().split(b"\0")
    collisions = set(open(collision_file, "rb").read().split(b"\0"))
    roots = [os.path.dirname(config).lstrip("/").rstrip("/"), state.lstrip("/").rstrip("/"), tls.lstrip("/").rstrip("/")]
    config_name = config.lstrip("/")
    status = 0
    for encoded in reversed(members):
        if not encoded or encoded == b"metadata" or encoded in collisions:
            continue
        name = os.fsdecode(encoded)
        if name != config_name and not any(name == p or name.startswith(p + "/") for p in roots[1:]):
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
    if len(sys.argv) < 6 or sys.argv[1] not in {"validate", "members0", "collisions0", "destinations", "skip-links0", "rollback-new", "copy-source"}:
        raise SystemExit(2)
    mode, archive, config, state, tls = sys.argv[1:6]
    if mode == "copy-source":
        if len(sys.argv) != 7:
            raise SystemExit(2)
        copy_source(archive, sys.argv[6])
        return
    if mode == "rollback-new":
        if len(sys.argv) != 8:
            raise SystemExit(2)
        raise SystemExit(rollback_new(sys.argv[6], sys.argv[7], config, state, tls))
    names = validate_archive(archive, config, state, tls)
    if mode == "destinations":
        if len(sys.argv) != 7:
            raise SystemExit(2)
        validate_destinations(names, sys.argv[6], config, state, tls)
    if mode == "skip-links0":
        if len(sys.argv) != 7:
            raise SystemExit(2)
        for name in validate_destinations(names, sys.argv[6], config, state, tls):
            sys.stdout.buffer.write(os.fsencode(name) + b"\0")
    if mode in {"members0", "collisions0"}:
        write_names(names, mode)


if __name__ == "__main__":
    main()
