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
import pwd
import grp
import json
import ctypes
import re
import gzip
import errno

ROOTLESS_GRAPHROOT_MEMBER = "rootless-graphroot.tar"
BACKUP_RESTORE_MARKER = "/var/lib/.localaictl-backup-restore.pending"
MAX_ARCHIVE_MEMBERS = 200_000
MAX_MEMBER_NAME_BYTES = 4096
MAX_PAX_HEADER_BYTES = 1024 * 1024
MAX_TOTAL_PAX_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_EXPANDED_BYTES = 16 * 1024**4


def fail(message: str) -> None:
    print(f"localaictl: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_tar_size(value: bytes) -> int:
    if len(value) != 12:
        fail("backup contains an invalid tar size field")
    if value[0] & 0x80:
        if value[0] & 0x40:
            fail("backup contains a negative tar size")
        return int.from_bytes(bytes((value[0] & 0x7f,)) + value[1:], "big")
    try:
        text = value.rstrip(b"\0 ").lstrip(b" ") or b"0"
        if any(byte not in b"01234567" for byte in text):
            fail("backup contains an invalid tar size field")
        return int(text, 8)
    except ValueError:
        fail("backup contains an invalid tar size field")


def validate_pax_payload(payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        separator = payload.find(b" ", offset)
        if separator < 0:
            fail("backup contains malformed pax metadata")
        try:
            length = int(payload[offset:separator])
        except ValueError:
            fail("backup contains malformed pax metadata")
        end = offset + length
        if length <= separator - offset + 1 or end > len(payload) or payload[end - 1:end] != b"\n":
            fail("backup contains malformed pax metadata")
        record = payload[separator + 1:end - 1]
        key, equals, value = record.partition(b"=")
        if not equals:
            fail("backup contains malformed pax metadata")
        if key in {b"path", b"linkpath"} and len(value) > MAX_MEMBER_NAME_BYTES:
            fail("backup contains an overlong archive member name")
        if key in {b"size", b"GNU.sparse.realsize", b"GNU.sparse.size"}:
            try:
                size = int(value)
            except ValueError:
                fail("backup contains malformed pax size metadata")
            if size < 0 or size > MAX_ARCHIVE_EXPANDED_BYTES:
                fail("backup exceeds the supported expanded-size limit")
        offset = end


def preflight_tar_stream(stream: object) -> None:
    try:
        seek = getattr(stream, "seek", None)
        if callable(seek):
            seek(0)
        count = 0
        total_size = 0
        total_pax = 0
        while True:
            header = stream.read(512)
            if not header:
                break
            if len(header) != 512:
                fail("backup contains a truncated tar header")
            if not any(header):
                break
            count += 1
            if count > MAX_ARCHIVE_MEMBERS:
                fail("backup exceeds the supported member-count limit")
            size = parse_tar_size(header[124:136])
            typeflag = header[156:157]
            name = header[:100].split(b"\0", 1)[0]
            prefix = header[345:500].split(b"\0", 1)[0]
            if prefix:
                name = prefix + b"/" + name
            if len(name) > MAX_MEMBER_NAME_BYTES:
                fail("backup contains an overlong archive member name")
            if typeflag in {b"x", b"g", b"L", b"K"}:
                if size > MAX_PAX_HEADER_BYTES:
                    fail("backup contains an oversized pax or long-name header")
                total_pax += size
                if total_pax > MAX_TOTAL_PAX_BYTES:
                    fail("backup exceeds the supported metadata-size limit")
                payload = stream.read(size)
                if len(payload) != size:
                    fail("backup contains a truncated pax or long-name header")
                if typeflag in {b"x", b"g"}:
                    validate_pax_payload(payload)
                elif len(payload.rstrip(b"\0")) > MAX_MEMBER_NAME_BYTES:
                    fail("backup contains an overlong archive member name")
            else:
                total_size += size
                if total_size > MAX_ARCHIVE_EXPANDED_BYTES:
                    fail("backup exceeds the supported expanded-size limit")
                remaining = size
                while remaining:
                    chunk = stream.read(min(1024 * 1024, remaining))
                    if not chunk:
                        fail("backup contains truncated member data")
                    remaining -= len(chunk)
            padding = (-size) % 512
            while padding:
                chunk = stream.read(min(512, padding))
                if not chunk:
                    fail("backup contains truncated member padding")
                padding -= len(chunk)
        if callable(seek):
            seek(0)
    except (OSError, EOFError, gzip.BadGzipFile):
        fail("backup preflight could not read archive data")


def preflight_gzip_archive(filename: str) -> None:
    try:
        with gzip.open(filename, "rb") as stream:
            preflight_tar_stream(stream)
    except (OSError, EOFError, gzip.BadGzipFile):
        fail("backup preflight could not read archive data")


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


def owner_id_policy(root_path: str) -> tuple[int, int, str, list[tuple[int, int]], list[tuple[int, int]]]:
    try:
        root = os.stat(root_path, follow_symlinks=False)
        if not stat.S_ISDIR(root.st_mode):
            fail("configured persistent root is not a directory")
        username = pwd.getpwuid(root.st_uid).pw_name
    except (OSError, KeyError):
        fail("cannot verify configured persistent root ownership")
    uid_ranges, _ = validated_subid_ranges(username, "/etc/subuid", {str(root.st_uid)})
    gid_ranges, _ = validated_subid_ranges(username, "/etc/subgid", {str(root.st_uid)})
    return root.st_uid, root.st_gid, username, uid_ranges, gid_ranges


def in_owner_policy(value: int, owner: int, ranges: list[tuple[int, int]]) -> bool:
    return value == owner or any(start <= value < end for start, end in ranges)


def sensitive_member(name: str) -> bool:
    basename = posixpath.basename(name).lower()
    return basename == "database.db" or basename.endswith((".key", ".p12", ".pfx")) or (
        "key" in basename and basename.endswith(".pem")
    )


def unsafe_archive_attributes(info: tarfile.TarInfo) -> bool:
    for key, value in info.pax_headers.items():
        normalized = key.lower()
        if (".acl." in normalized or "posix_acl" in normalized or
                normalized.startswith("schily.acl") or normalized.startswith("libarchive.acl")):
            return True
        if normalized.endswith("security.selinux") and value:
            return True
    return False


def read_metadata(archive: tarfile.TarFile) -> dict[str, str]:
    members = [info for info in archive if clean_member_name(info.name) == "metadata"]
    if len(members) != 1 or not members[0].isfile():
        fail("backup metadata is missing")
    stream = archive.extractfile(members[0])
    if stream is None:
        fail("backup metadata is unreadable")
    try:
        raw = stream.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            fail("backup metadata is too large")
        lines = raw.decode("ascii").splitlines()
    except (OSError, UnicodeError):
        fail("backup metadata is invalid")
    values: dict[str, str] = {}
    for line in lines:
        if "=" not in line:
            fail("backup metadata is invalid")
        key, value = line.split("=", 1)
        if not key or key in values:
            fail("backup metadata is invalid")
        values[key] = value
    return values


def read_rootless_context(filename: str) -> dict[str, str | int]:
    try:
        fd = os.open(filename, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or
                stat.S_IMODE(metadata.st_mode) != 0o600):
            os.close(fd)
            fail("verified rootless service context has unsafe ownership or mode")
        with os.fdopen(fd, "r", encoding="ascii") as stream:
            context = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("cannot read the verified rootless service context")
    required = {"graphroot", "uid_map", "gid_map", "service_home", "service_uid", "service_gid", "service_user"}
    if not isinstance(context, dict) or set(context) != required:
        fail("verified rootless service context is incomplete")
    if any(not isinstance(context[key], str) or not context[key] for key in required - {"service_uid", "service_gid"}):
        fail("verified rootless service context is invalid")
    if any(not isinstance(context[key], int) or context[key] < 0 for key in ("service_uid", "service_gid")):
        fail("verified rootless service context is invalid")
    for key in ("graphroot", "service_home"):
        value = str(context[key])
        if not value.startswith("/") or os.path.normpath(value) != value or "\n" in value or "\r" in value:
            fail("verified rootless service context is invalid")
    if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", str(context["service_user"])) or
            context["service_user"] in {"root", "0"}):
        fail("verified rootless service context is invalid")
    return context


def valid_service_account_name(value: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", value)) and value not in {"root", "0"}


def parse_id_map(value: str) -> list[tuple[int, int, int]]:
    result: list[tuple[int, int, int]] = []
    for row in value.split(";"):
        fields = row.split(":")
        if len(fields) != 3 or not all(field.isdecimal() for field in fields):
            fail("rootless backup contains an invalid user namespace map")
        inside, outside, length = (int(field) for field in fields)
        if length < 1 or inside < 0 or outside < 0:
            fail("rootless backup contains an invalid user namespace map")
        result.append((inside, outside, length))
    if not result:
        fail("rootless backup contains an invalid user namespace map")
    return result


def subid_ranges(account: str, filename: str, aliases: set[str] | None = None) -> tuple[list[tuple[int, int]], list[tuple[str, int, int]]]:
    account_names = {account, *(aliases or set())}
    own: list[tuple[int, int]] = []
    all_ranges: list[tuple[str, int, int]] = []
    try:
        with open(filename, encoding="ascii") as stream:
            for line in stream:
                fields = line.rstrip("\n").split(":")
                if len(fields) != 3 or not fields[1].isdecimal() or not fields[2].isdecimal():
                    fail("cannot verify rootless subordinate ID ranges")
                start, length = int(fields[1]), int(fields[2])
                if length < 1:
                    fail("cannot verify rootless subordinate ID ranges")
                all_ranges.append((fields[0], start, start + length))
                if fields[0] in account_names:
                    own.append((start, start + length))
    except OSError:
        fail("cannot verify rootless subordinate ID ranges")
    return own, all_ranges


def validated_subid_ranges(account: str, filename: str, aliases: set[str] | None = None) -> tuple[list[tuple[int, int]], list[tuple[str, int, int]]]:
    account_names = {account, *(aliases or set())}
    own_ranges, all_ranges = subid_ranges(account, filename, aliases)
    account_file = "/etc/passwd" if filename.endswith("subuid") else "/etc/group"
    try:
        with open(account_file, encoding="ascii") as stream:
            for line in stream:
                fields = line.rstrip("\n").split(":")
                if len(fields) > 2 and fields[2].isdecimal():
                    identity = int(fields[2])
                    if any(start <= identity < stop for start, stop in own_ranges):
                        fail("subordinate ID ranges collide with a local account")
    except OSError:
        fail("cannot verify local subordinate ID collisions")
    for other, start, stop in all_ranges:
        if other not in account_names and any(start < own_stop and own_start < stop for own_start, own_stop in own_ranges):
            fail("subordinate ID ranges overlap another account")
    return own_ranges, all_ranges


def validate_id_map(value: str, primary_id: int, account: str, filename: str) -> list[tuple[int, int, int]]:
    mapping = parse_id_map(value)
    if mapping[0][0] != 0 or mapping[0][1] != primary_id or mapping[0][2] != 1:
        fail("rootless namespace does not map its owner to the service account")
    try:
        service_uid = pwd.getpwnam(account).pw_uid
    except KeyError:
        fail("rootless service account does not exist")
    aliases = {str(service_uid)}
    account_aliases = {account, *aliases}
    own_ranges, all_ranges = validated_subid_ranges(account, filename, aliases)
    expected_inside = 1
    outside_ranges: list[tuple[int, int]] = []
    for inside, outside, length in mapping[1:]:
        if inside != expected_inside:
            fail("rootless namespace mapping is not contiguous")
        expected_inside += length
        end = outside + length
        if not any(start <= outside and end <= stop for start, stop in own_ranges):
            fail("rootless namespace maps IDs outside the service subordinate range")
        for other, start, stop in all_ranges:
            if other not in account_aliases and outside < stop and start < end:
                fail("rootless namespace ID ranges overlap another account")
        if any(outside < stop and start < end for start, stop in outside_ranges):
            fail("rootless namespace ID ranges overlap")
        outside_ranges.append((outside, end))
    return mapping


def mapped_id(value: int, mapping: list[tuple[int, int, int]]) -> bool:
    return any(inside <= value < inside + length for inside, _outside, length in mapping)


def graphroot_mounts(graphroot: str, mountinfo: str = "/proc/self/mountinfo") -> list[str]:
    mounted: list[str] = []
    try:
        with open(mountinfo, encoding="ascii") as stream:
            for line in stream:
                fields = line.split(" - ", 1)[0].split()
                if len(fields) < 5:
                    fail("cannot verify rootless graphroot mount state")
                target = fields[4]
                for escaped, actual in (("\\040", " "), ("\\011", "\t"), ("\\134", "\\")):
                    target = target.replace(escaped, actual)
                if target == graphroot or target.startswith(graphroot.rstrip("/") + "/"):
                    mounted.append(target)
    except OSError:
        fail("cannot verify rootless graphroot mount state")
    return mounted


def validate_graphroot_path(
    graphroot: str,
    service_home: str,
    service_uid: int,
    service_gid: int,
    roots: list[str],
) -> None:
    if not graphroot.startswith("/") or graphroot == "/" or os.path.normpath(graphroot) != graphroot:
        fail("configured rootless graphroot path is unsafe")
    if not any(graphroot == root or graphroot.startswith(root.rstrip("/") + "/") for root in roots):
        fail("configured rootless graphroot is outside the persistent backup roots")
    under_home = graphroot == service_home or graphroot.startswith(service_home.rstrip("/") + "/")
    persistent_matches = [root for root in roots if graphroot == root or graphroot.startswith(root.rstrip("/") + "/")]
    external_root = max(persistent_matches, key=len) if persistent_matches else None
    if not under_home and external_root is None:
        fail("configured external rootless graphroot is not a persistent path")
    graphroot_exists = os.path.lexists(graphroot)
    if os.path.realpath(graphroot) != graphroot:
        fail("configured rootless graphroot path contains a symbolic link")
    current = graphroot if graphroot_exists else os.path.dirname(graphroot)
    chain: list[str] = []
    while current != "/":
        chain.append(current)
        current = os.path.dirname(current)
    chain.append("/")
    home_chain = set()
    if under_home:
        current = graphroot if graphroot_exists else os.path.dirname(graphroot)
        while current != service_home:
            home_chain.add(current)
            current = os.path.dirname(current)
        home_chain.add(service_home)
    private_chain = set()
    if not under_home and external_root is not None:
        current = graphroot if graphroot_exists else os.path.dirname(graphroot)
        while current != external_root:
            private_chain.add(current)
            current = os.path.dirname(current)
        private_chain.add(external_root)
    for path in reversed(chain):
        try:
            info = os.lstat(path)
        except OSError:
            fail("configured rootless graphroot ancestry cannot be verified")
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            fail("configured rootless graphroot ancestry is not a directory")
        if info.st_mode & 0o022:
            fail("configured rootless graphroot ancestry is group/world writable")
        try:
            names = os.listxattr(path, follow_symlinks=False)
            if any(name in {"system.posix_acl_access", "system.posix_acl_default"} for name in names):
                fail("configured rootless graphroot ancestry has an ACL")
        except OSError:
            fail("configured rootless graphroot ACLs cannot be verified")
        if path == graphroot:
            continue
        if path in home_chain or path in private_chain:
            mode = stat.S_IMODE(info.st_mode)
            if path == service_home:
                # The installer creates the service home as 0750; group read
                # and search are safe only for the dedicated service group.
                unsafe_mode = (mode & 0o700 != 0o700 or mode & 0o027 != 0 or
                               info.st_mode & 0o7000 != 0)
                if (info.st_uid != service_uid or info.st_gid != service_gid or unsafe_mode):
                    fail("configured rootless graphroot service home is public or has unexpected ownership")
            elif info.st_uid != service_uid or mode & 0o077 or info.st_mode & 0o7000:
                fail("configured rootless graphroot service-home ancestry is public")
        elif path != "/" and info.st_uid != 0:
            fail("configured rootless graphroot ancestry has an unexpected owner")
    if graphroot_exists:
        try:
            root_info = os.lstat(graphroot)
        except OSError:
            fail("configured rootless graphroot is unavailable")
        root_mode = stat.S_IMODE(root_info.st_mode)
        if (not stat.S_ISDIR(root_info.st_mode) or
                (root_info.st_uid, root_info.st_gid) != (service_uid, service_gid) or
                root_mode & 0o700 != 0o700 or root_mode & 0o077 or root_info.st_mode & 0o7000):
            fail("configured rootless graphroot has unsafe owner or mode")
    if graphroot_mounts(graphroot):
        fail("configured rootless graphroot contains a mount point")


def open_directory_nofollow(path: str) -> int:
    if not path.startswith("/") or os.path.normpath(path) != path:
        fail("rootless graphroot parent path is unsafe")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open("/", flags)
    try:
        for component in path.split("/")[1:]:
            if not component:
                continue
            next_fd = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except OSError:
        os.close(fd)
        fail("rootless graphroot parent contains an unsafe path component")


def rename_graphroot_noreplace(source: str, destination: str, expected: tuple[int, int] | None = None) -> None:
    if (not source.startswith("/") or not destination.startswith("/") or
            os.path.normpath(source) != source or os.path.normpath(destination) != destination or
            os.path.dirname(source) != os.path.dirname(destination)):
        fail("rootless graphroot rename paths are invalid")
    source_name = os.path.basename(source)
    destination_name = os.path.basename(destination)
    if source_name in {"", ".", ".."} or destination_name in {"", ".", ".."}:
        fail("rootless graphroot rename paths are invalid")
    try:
        parent_fd = open_directory_nofollow(os.path.dirname(source))
    except OSError:
        fail("rootless graphroot rename source or parent is unsafe")
    try:
        try:
            source_info = os.stat(source_name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError:
            fail("rootless graphroot rename source or parent is unsafe")
        if not stat.S_ISDIR(source_info.st_mode) or stat.S_ISLNK(source_info.st_mode):
            fail("rootless graphroot rename source is not a directory")
        if expected is not None and (source_info.st_dev, source_info.st_ino) != expected:
            fail("rootless graphroot rollback identity does not match")
        try:
            os.stat(destination_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            fail("rootless graphroot rollback destination already exists")
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        result = renameat2(parent_fd, os.fsencode(source_name), parent_fd, os.fsencode(destination_name), 1)
        if result != 0:
            error_number = ctypes.get_errno()
            fail("rootless graphroot no-replace rename failed" if error_number != 17 else "rootless graphroot rollback destination already exists")
        renamed_info = os.stat(destination_name, dir_fd=parent_fd, follow_symlinks=False)
        if expected is not None and (renamed_info.st_dev, renamed_info.st_ino) != expected:
            fail("rootless graphroot identity changed during rename; recovery marker retained")
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def create_graphroot_noreplace(path: str, service_uid: int, service_gid: int) -> None:
    if not path.startswith("/") or os.path.normpath(path) != path:
        fail("rootless graphroot creation path is invalid")
    parent = os.path.dirname(path)
    name = os.path.basename(path)
    if name in {"", ".", ".."}:
        fail("rootless graphroot creation path is invalid")
    try:
        parent_fd = open_directory_nofollow(parent)
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        os.chown(name, service_uid, service_gid, dir_fd=parent_fd, follow_symlinks=False)
        os.fsync(parent_fd)
    except FileExistsError:
        fail("rootless graphroot destination already exists")
    except OSError:
        fail("rootless graphroot destination could not be created safely")
    finally:
        if "parent_fd" in locals():
            os.close(parent_fd)


def remove_tree_at(parent_fd: int, name: str) -> None:
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(metadata.st_mode):
        child_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_fd,
        )
        try:
            child_metadata = os.fstat(child_fd)
            if (child_metadata.st_dev, child_metadata.st_ino) != (metadata.st_dev, metadata.st_ino):
                fail("rootless graphroot changed during safe removal")
            for child in os.listdir(child_fd):
                remove_tree_at(child_fd, child)
        finally:
            os.close(child_fd)
        try:
            os.rmdir(name, dir_fd=parent_fd)
        except OSError:
            fail("rootless graphroot changed during safe removal")
    else:
        try:
            os.unlink(name, dir_fd=parent_fd)
        except OSError:
            fail("rootless graphroot changed during safe removal")


def remove_graphroot_nofollow(path: str, expected_device: int, expected_inode: int) -> None:
    if not path.startswith("/") or os.path.normpath(path) != path:
        fail("rootless graphroot removal path is invalid")
    parent_fd = open_directory_nofollow(os.path.dirname(path))
    try:
        name = os.path.basename(path)
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != (expected_device, expected_inode):
            fail("rootless graphroot removal identity does not match")
        if graphroot_mounts(path):
            fail("rootless graphroot removal contains a mount point")
        remove_tree_at(parent_fd, name)
    finally:
        os.close(parent_fd)


def validate_graphroot_tar(
    archive_file: object,
    graphroot: str,
    uid_map_value: str,
    gid_map_value: str,
    live_uid_map_value: str,
    live_gid_map_value: str,
    service_user: str,
) -> list[str]:
    preflight_tar_stream(archive_file)
    try:
        passwd_entry = pwd.getpwnam(service_user)
        group_entry = grp.getgrnam(service_user)
    except KeyError:
        fail("cannot verify the rootless service account")
    if parse_id_map(uid_map_value) != parse_id_map(live_uid_map_value):
        fail("rootless archive UID mapping differs from the installed service")
    if parse_id_map(gid_map_value) != parse_id_map(live_gid_map_value):
        fail("rootless archive GID mapping differs from the installed service")
    uid_map = validate_id_map(uid_map_value, passwd_entry.pw_uid, service_user, "/etc/subuid")
    gid_map = validate_id_map(gid_map_value, group_entry.gr_gid, service_user, "/etc/subgid")
    prefix = os.path.basename(graphroot.rstrip("/"))
    members: dict[str, tarfile.TarInfo] = {}
    try:
        with tarfile.open(fileobj=archive_file, mode="r:") as nested:
            for info in nested:
                name = clean_member_name(info.name)
                if name != prefix and not name.startswith(prefix + "/"):
                    fail("rootless archive contains a path outside its graphroot")
                relative = name[len(prefix):].lstrip("/")
                if name in members:
                    fail("rootless archive contains duplicate member names")
                if not (info.isfile() or info.isdir() or info.issym() or info.islnk()):
                    fail("rootless archive contains an unsupported special file")
                if not mapped_id(info.uid, uid_map) or not mapped_id(info.gid, gid_map):
                    fail("rootless archive contains an unmapped owner or group")
                if info.mode & 0o4000 and info.uid == 0:
                    fail("rootless archive has setuid ownership mapped to the service account")
                if info.mode & 0o2000 and info.gid == 0:
                    fail("rootless archive has setgid ownership mapped to the service group")
                if any(key.lower().endswith("security.capability") and value for key, value in info.pax_headers.items()):
                    fail("rootless archive contains a file capability xattr")
                if any("acl" in key.lower() and value for key, value in info.pax_headers.items()):
                    fail("rootless archive contains an unverified ACL")
                if info.issym():
                    link = info.linkname
                    if "\x00" in link or "\n" in link or "\r" in link:
                        fail("rootless archive contains an unsafe symbolic link")
                    if not link.startswith("/"):
                        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), link))
                        if resolved == ".." or resolved.startswith("../"):
                            fail("rootless archive contains a symbolic link escaping its graphroot")
                members[name] = info
            trailing = nested.fileobj.read(10241)
            if len(trailing) > 10240 or any(trailing):
                fail("rootless archive contains unvalidated trailing data")
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot read rootless graphroot archive ({type(error).__name__})")
    root = members.get(prefix)
    if (root is None or not root.isdir() or root.uid != 0 or root.gid != 0 or
            root.mode & 0o700 != 0o700 or root.mode & 0o077 or root.mode & 0o7000):
        fail("rootless archive graphroot root is missing or not a directory")
    for name, info in members.items():
        label_values = [value.encode("utf-8", "surrogateescape").rstrip(b"\0")
                        for key, value in info.pax_headers.items()
                        if key.lower().endswith("security.selinux")]
        if len(label_values) > 1:
            fail("rootless archive contains duplicate SELinux labels")
        relative = name[len(prefix):].lstrip("/")
        live_path = graphroot if not relative else os.path.join(graphroot, *relative.split("/"))
        if not os.path.lexists(live_path):
            if label_values:
                fail("rootless archive SELinux label has no installed baseline")
            continue
        try:
            live_label = os.getxattr(live_path, "security.selinux", follow_symlinks=False).rstrip(b"\0")
        except OSError as error:
            if error.errno in {getattr(errno, "ENODATA", 61), getattr(errno, "ENOATTR", 61)}:
                live_label = b""
            else:
                fail("cannot verify rootless archive SELinux labels")
        archived_label = label_values[0] if label_values else b""
        if archived_label != live_label:
            fail("rootless archive SELinux label differs from its installed baseline")
    for name, info in members.items():
        if info.islnk():
            target = clean_member_name(info.linkname)
            target_info = members.get(target)
            if target_info is None or not target_info.isfile():
                fail("rootless archive contains an invalid hard link")
            if (info.uid, info.gid, info.mode) != (target_info.uid, target_info.gid, target_info.mode):
                fail("rootless archive hard link metadata differs from its target")
            if info.mode & 0o6000 or target_info.mode & 0o6000:
                fail("rootless archive has a hard link to a privileged member")
        parent = posixpath.dirname(name)
        while parent:
            if parent in members and not members[parent].isdir():
                fail("rootless archive nests a member below a non-directory entry")
            parent = posixpath.dirname(parent)
    return sorted(members)


def validate_archive(
    archive: str,
    config: str,
    roots: list[str],
    *,
    require_root_config: bool = True,
    rootless_context: dict[str, str | int] | None = None,
) -> list[str]:
    preflight_gzip_archive(archive)
    config_name = config.lstrip("/")
    prefixes = [p.lstrip("/").rstrip("/") for p in roots]
    if any(not p for p in prefixes) or len(set(prefixes)) != len(prefixes):
        fail("configured backup paths must be distinct absolute paths")
    graphroot_prefix = None if rootless_context is None else str(rootless_context["graphroot"]).lstrip("/").rstrip("/")
    members: dict[str, tarfile.TarInfo] = {}
    persistent_owner_policies: dict[str, tuple[int, int, str, list[tuple[int, int]], list[tuple[int, int]]]] = {}
    nested_member: tarfile.TarInfo | None = None
    try:
        fd = os.open(archive, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            fail("backup must be a regular non-linked file")
        with os.fdopen(fd, "rb") as stream, tarfile.open(fileobj=stream, mode="r:gz") as source:
            for info in source:
                name = clean_member_name(info.name)
                if name in members or (nested_member is not None and name == ROOTLESS_GRAPHROOT_MEMBER):
                    fail("backup contains duplicate member names")
                if name == ROOTLESS_GRAPHROOT_MEMBER:
                    if not info.isfile() or info.uid != 0 or info.gid != 0 or info.mode & 0o6077:
                        fail("backup rootless graphroot archive member is unsafe")
                    nested_member = info
                    continue
                if graphroot_prefix and (name == graphroot_prefix or name.startswith(graphroot_prefix + "/")):
                    fail("backup stores rootless graphroot outside its nested archive")
                if has_systemd_tree(name, "system", roots):
                    fail("backup contains system manager unit configuration")
                if name != "metadata" and name != config_name and member_root(name, prefixes) is None:
                    fail("backup contains a path outside configured LocalAI paths")
                if not (info.isfile() or info.isdir() or info.issym() or info.islnk()):
                    fail("backup contains an unsupported special file")
                if info.mode & 0o6000:
                    fail("backup contains setuid or setgid permission bits")
                if not info.issym() and info.mode & 0o022:
                    fail("backup contains group/world-writable permissions")
                if any(key.lower().endswith("security.capability") and value for key, value in info.pax_headers.items()):
                    fail("backup contains a file capability xattr")
                if unsafe_archive_attributes(info):
                    fail("backup contains an unsupported ACL or SELinux label")
                if name == config_name:
                    expected_uid = 0 if require_root_config else os.stat(config, follow_symlinks=False).st_uid
                    expected_gid = 0 if require_root_config else os.stat(config, follow_symlinks=False).st_gid
                    if (not info.isfile() or info.uid != expected_uid or info.gid != expected_gid or
                            info.mode & 0o022 or info.mode & 0o111):
                        ownership = "root-owned" if require_root_config else "owned by its source file owner"
                        fail(f"backup configuration member must be a {ownership} regular file without write or execute permissions")
                if name in prefixes and (not info.isdir() or info.mode & 0o700 != 0o700):
                    fail("configured persistent root must be an owner-writable directory")
                if name != config_name and name != "metadata":
                    root_name = member_root(name, prefixes)
                    if root_name is None:
                        fail("backup contains a path outside configured LocalAI paths")
                    if root_name not in persistent_owner_policies:
                        persistent_owner_policies[root_name] = owner_id_policy("/" + root_name)
                    expected_uid, expected_gid, _username, uid_ranges, gid_ranges = persistent_owner_policies[root_name]
                    if name == root_name and (info.uid, info.gid) != (expected_uid, expected_gid):
                        fail("backup persistent root ownership differs from the installed root")
                    if (not in_owner_policy(info.uid, expected_uid, uid_ranges) or
                            not in_owner_policy(info.gid, expected_gid, gid_ranges)):
                        fail("backup member ownership is outside the configured service account")
                    if sensitive_member(name) and info.mode & 0o027:
                        fail("backup contains public or writable permissions on sensitive state")
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
            target_info = members[target]
            if (info.uid, info.gid, info.mode) != (target_info.uid, target_info.gid, target_info.mode):
                fail("backup hard link metadata differs from its target")
            if sensitive_member(name) and target_info.mode & 0o027:
                fail("backup sensitive hard link target has public or writable permissions")
    if "metadata" not in members or not members["metadata"].isfile():
        fail("backup metadata is missing")
    if nested_member is not None:
        if rootless_context is None:
            fail("backup rootless graphroot archive has no verified service context")
        if not os.path.isdir(str(rootless_context["graphroot"])) or os.path.islink(str(rootless_context["graphroot"])):
            fail("backup rootless graphroot destination is unavailable")
        with tarfile.open(archive, "r:gz") as source:
            metadata = read_metadata(source)
            expected_metadata = {
                "graphroot": str(rootless_context["graphroot"]),
                "uid_map": str(rootless_context["uid_map"]),
                "gid_map": str(rootless_context["gid_map"]),
            }
            if any(metadata.get(key) != value for key, value in expected_metadata.items()):
                fail("backup rootless service settings differ from the installed service")
            if metadata.get("format") != "2":
                fail("backup rootless graphroot format is unsupported")
            validate_graphroot_path(
                expected_metadata["graphroot"],
                str(rootless_context["service_home"]),
                int(rootless_context["service_uid"]),
                int(rootless_context["service_gid"]),
                roots,
            )
            stream = source.extractfile(nested_member)
            if stream is None:
                fail("backup rootless graphroot archive is unreadable")
            validate_graphroot_tar(
                stream,
                expected_metadata["graphroot"],
                expected_metadata["uid_map"],
                expected_metadata["gid_map"],
                str(rootless_context["uid_map"]),
                str(rootless_context["gid_map"]),
                str(rootless_context["service_user"]),
            )
    elif rootless_context is not None and os.path.lexists(str(rootless_context["graphroot"])):
        fail("backup omits the installed rootless graphroot")
    return list(members)


def copy_source(source: str, destination: str) -> None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        source_fd = os.open(source, flags)
    except OSError:
        fail("restore source must be a regular non-linked file")
    destination_fd = -1
    try:
        initial = os.fstat(source_fd)
        if not stat.S_ISREG(initial.st_mode) or initial.st_size < 0 or initial.st_size > MAX_ARCHIVE_EXPANDED_BYTES:
            fail("restore source must be a supported regular file")
        destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                 getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), 0o600)
        remaining = initial.st_size
        while remaining:
            chunk = os.read(source_fd, min(1024 * 1024, remaining))
            if not chunk:
                fail("restore source changed while it was being staged")
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    fail("could not stage restore source safely")
                view = view[written:]
            remaining -= len(chunk)
        final = os.fstat(source_fd)
        path_final = os.stat(source, follow_symlinks=False)
        identity_before = (initial.st_dev, initial.st_ino, initial.st_size, initial.st_mtime_ns, initial.st_ctime_ns)
        identity_after = (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns, final.st_ctime_ns)
        path_identity = (path_final.st_dev, path_final.st_ino, path_final.st_size, path_final.st_mtime_ns, path_final.st_ctime_ns)
        if not stat.S_ISREG(path_final.st_mode):
            fail("restore source path changed to a non-regular file while it was being staged")
        if identity_before != identity_after:
            fail("restore source descriptor changed while it was being staged")
        if identity_before != path_identity:
            fail("restore source changed while it was being staged")
        os.fchmod(destination_fd, 0o600)
        os.fsync(destination_fd)
    except SystemExit:
        try:
            os.unlink(destination)
        except FileNotFoundError:
            pass
        raise
    except OSError:
        try:
            os.unlink(destination)
        except FileNotFoundError:
            pass
        fail("could not stage restore source safely")
    finally:
        os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)


def sync_restore_filesystems(
    archive_path: str,
    config: str,
    roots: list[str],
    rootless_context: dict[str, str | int] | None = None,
) -> None:
    synced: set[tuple[int, int]] = set()

    def sync_path(path: str) -> None:
        probe = nearest_existing_path(path)
        metadata = os.stat(probe, follow_symlinks=False)
        filesystem = os.statvfs(probe)
        key = (metadata.st_dev, int(getattr(filesystem, "f_fsid", metadata.st_dev)))
        if key in synced:
            return
        descriptor = open_directory_nofollow(probe)
        try:
            syncfs = ctypes.CDLL(None, use_errno=True).syncfs
            syncfs.argtypes = [ctypes.c_int]
            syncfs.restype = ctypes.c_int
            if syncfs(descriptor) != 0:
                fail("could not durably flush restored data and directory metadata")
        finally:
            os.close(descriptor)
        synced.add(key)

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for info in archive:
                name = clean_member_name(info.name)
                if name == "metadata":
                    continue
                if name == ROOTLESS_GRAPHROOT_MEMBER:
                    if rootless_context is None:
                        fail("cannot durably flush an unverified rootless graphroot")
                    nested_stream = archive.extractfile(info)
                    if nested_stream is None:
                        fail("cannot read rootless graphroot for durable flush")
                    preflight_tar_stream(nested_stream)
                    with tarfile.open(fileobj=nested_stream, mode="r:") as nested:
                        graphroot = str(rootless_context["graphroot"])
                        prefix = posixpath.basename(graphroot.rstrip("/"))
                        for nested_info in nested:
                            nested_name = clean_member_name(nested_info.name)
                            if nested_name != prefix and not nested_name.startswith(prefix + "/"):
                                fail("rootless archive contains a path outside its graphroot")
                            relative = nested_name[len(prefix):].lstrip("/")
                            target = graphroot if not relative else os.path.join(graphroot, *relative.split("/"))
                            sync_path(target if nested_info.isdir() else os.path.dirname(target))
                    continue
                target = "/" + name
                sync_path(target if info.isdir() else os.path.dirname(target))
            sync_path(os.path.dirname(config))
    except (OSError, tarfile.TarError) as error:
        fail(f"could not durably flush restored filesystems ({type(error).__name__})")


def sync_staging_snapshot(snapshot: str, stage: str) -> None:
    """Persist the rollback archive and staging directory before live mutation."""
    try:
        if os.path.lexists(snapshot):
            fd = os.open(snapshot, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
                         getattr(os, "O_CLOEXEC", 0))
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode):
                    fail("rollback snapshot is not a regular file")
                os.fsync(fd)
            finally:
                os.close(fd)
            parent_fd = open_directory_nofollow(os.path.dirname(snapshot))
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
        stage_fd = open_directory_nofollow(stage)
        try:
            os.fsync(stage_fd)
        finally:
            os.close(stage_fd)
    except OSError:
        fail("could not durably persist rollback snapshot and staging directory")


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


def transaction_marker_open_parent(path: str) -> tuple[int, str]:
    if not path.startswith("/") or os.path.normpath(path) != path:
        fail("backup restore transaction marker path is invalid")
    parent_path, name = os.path.dirname(path), os.path.basename(path)
    if name in {"", ".", ".."}:
        fail("backup restore transaction marker path is invalid")
    try:
        parent_fd = open_directory_nofollow(parent_path)
        parent_info = os.fstat(parent_fd)
    except OSError:
        fail("backup restore transaction marker parent is unsafe")
    if (parent_info.st_uid != os.geteuid() or parent_info.st_mode & 0o022 or
            not stat.S_ISDIR(parent_info.st_mode)):
        os.close(parent_fd)
        fail("backup restore transaction marker parent is unsafe")
    return parent_fd, name


def read_transaction_marker(path: str = BACKUP_RESTORE_MARKER) -> dict[str, str]:
    parent_fd, name = transaction_marker_open_parent(path)
    try:
        try:
            fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=parent_fd)
        except FileNotFoundError:
            return {}
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
                stat.S_IMODE(info.st_mode) != 0o644 or info.st_mode & 0o022):
            os.close(fd)
            fail("backup restore transaction marker has unsafe ownership or mode")
        with os.fdopen(fd, "r", encoding="ascii") as stream:
            marker = json.load(stream)
        if (not isinstance(marker, dict) or
                set(marker) != {"format", "graphroot", "rollback_path", "graphroot_inode"} or
                marker.get("format") != 1 or
                any(not isinstance(marker[key], str) for key in ("graphroot", "rollback_path", "graphroot_inode"))):
            fail("backup restore transaction marker is malformed")
        return marker
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("cannot read backup restore transaction marker")
    finally:
        os.close(parent_fd)


def check_transaction_marker(path: str = BACKUP_RESTORE_MARKER) -> None:
    if read_transaction_marker(path):
        fail("a previous backup restore is incomplete; managed services remain blocked pending recovery")


def create_transaction_marker(graphroot: str, rollback_path: str, graphroot_inode: str,
                              path: str = BACKUP_RESTORE_MARKER) -> None:
    if bool(graphroot) != bool(rollback_path) or bool(graphroot) != bool(graphroot_inode):
        fail("backup restore transaction marker arguments are incomplete")
    for value in (graphroot, rollback_path):
        if value and (not value.startswith("/") or os.path.normpath(value) != value):
            fail("backup restore transaction marker paths are invalid")
    if graphroot and os.path.dirname(graphroot) != os.path.dirname(rollback_path):
        fail("backup restore transaction marker paths are invalid")
    parent_fd, name = transaction_marker_open_parent(path)
    payload = json.dumps({"format": 1, "graphroot": graphroot,
                          "rollback_path": rollback_path,
                          "graphroot_inode": graphroot_inode}, separators=(",", ":")).encode("ascii") + b"\n"
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) |
                     getattr(os, "O_CLOEXEC", 0), 0o644, dir_fd=parent_fd)
        try:
            os.fchown(fd, os.geteuid(), os.getegid())
            os.fchmod(fd, 0o644)
            with os.fdopen(fd, "wb", closefd=False) as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(parent_fd)
    except FileExistsError:
        fail("a previous backup restore is incomplete; managed services remain blocked pending recovery")
    except OSError:
        fail("could not create a durable backup restore transaction marker")
    finally:
        os.close(parent_fd)
    read_transaction_marker(path)


def clear_transaction_marker(path: str = BACKUP_RESTORE_MARKER) -> None:
    parent_fd, name = transaction_marker_open_parent(path)
    try:
        try:
            info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
                stat.S_IMODE(info.st_mode) != 0o644 or info.st_mode & 0o022):
            fail("backup restore transaction marker has unsafe ownership or mode")
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    except OSError:
        fail("could not clear backup restore transaction marker safely")
    finally:
        os.close(parent_fd)


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
        if name != "security.selinux"
    }
    installed_xattrs = {
        name: os.getxattr(installed, name, follow_symlinks=False)
        for name in os.listxattr(installed, follow_symlinks=False)
        if name != "security.selinux"
    }
    return staged_xattrs == installed_xattrs


def unit_trees(
    archive_path: str,
    stage: str,
    config: str,
    roots: list[str],
    expected_roots: list[str],
    rootless_context: dict[str, str | int] | None = None,
) -> list[str]:
    names = validate_archive(archive_path, config, roots, rootless_context=rootless_context)
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


def backup_space_check(
    archive_path: str,
    stage: str,
    graphroot: str,
    roots: list[str],
    exclude_path: str | None = None,
) -> None:
    payload = 0
    entries = 0
    nested_payload = 0
    nested_entries = 0

    def scan_tree(path: str, *, skip: list[str]) -> tuple[int, int, int]:
        total = 0
        count = 0
        headers = 0
        if any(path == ignored or path.startswith(ignored.rstrip("/") + "/") for ignored in skip):
            return total, count, headers
        if not os.path.lexists(path):
            return total, count, headers
        def walk_error(_error: OSError) -> None:
            fail("cannot estimate backup storage requirements")

        for current, directories, files in os.walk(path, topdown=True, onerror=walk_error, followlinks=False):
            directories[:] = [name for name in directories if not any(
                os.path.join(current, name) == ignored or os.path.join(current, name).startswith(ignored.rstrip("/") + "/")
                for ignored in skip
            )]
            for name in [*directories, *files]:
                member = os.path.join(current, name)
                if any(member == ignored or member.startswith(ignored.rstrip("/") + "/") for ignored in skip):
                    continue
                try:
                    info = os.lstat(member)
                    count += 1
                    path_blocks = (len(os.fsencode(member)) + 511) // 512
                    headers += max(1024, (path_blocks + 1) * 512)
                    if stat.S_ISREG(info.st_mode):
                        total += info.st_size
                    elif stat.S_ISLNK(info.st_mode):
                        total += len(os.fsencode(os.readlink(member)))
                    for attr in os.listxattr(member, follow_symlinks=False):
                        total += len(os.getxattr(member, attr, follow_symlinks=False))
                except OSError:
                    fail("cannot estimate backup storage requirements")
        return total, count, headers

    for root in roots:
        if root == graphroot:
            continue
        skips = [path for path in (graphroot, exclude_path) if path]
        current_size, current_count, current_headers = scan_tree(root, skip=skips)
        payload += current_size
        entries += current_count
        payload += current_headers
    nested_payload, nested_entries, nested_headers = scan_tree(graphroot, skip=[])
    nested_size = nested_payload + nested_headers + 10240
    outer_size = payload + entries * 1024 + nested_size + 10240
    archive_size = outer_size + outer_size // 100 + 1024 * 1024
    stage_size = nested_size + 1024 * 1024
    by_fs: dict[tuple[int, int], dict[str, int]] = {}

    def charge(path: str, amount: int, inodes: int) -> None:
        probe = nearest_existing_path(path)
        filesystem = os.statvfs(probe)
        metadata = os.stat(probe, follow_symlinks=False)
        key = (metadata.st_dev, int(getattr(filesystem, "f_fsid", metadata.st_dev)))
        usage = by_fs.setdefault(key, {"path": probe, "bytes": 0, "inodes": 0,
                                      "free_inodes": filesystem.f_favail, "total_inodes": filesystem.f_files})
        usage["bytes"] += amount
        usage["inodes"] += inodes

    try:
        charge(stage, stage_size, 1)
        charge(archive_path, archive_size, 0)
    except OSError:
        fail("cannot inspect backup destination filesystems")
    for usage in by_fs.values():
        if shutil.disk_usage(usage["path"]).free < usage["bytes"]:
            fail("insufficient disk space for backup staging and archive output")
        if usage["total_inodes"] and usage["free_inodes"] < usage["inodes"] + 8:
            fail("insufficient free inodes for backup staging")


def space_check(
    archive_path: str,
    stage: str,
    collision_file: str | None = None,
    destinations: list[str] | None = None,
    *,
    staged: bool = False,
    rootless_context: dict[str, str | int] | None = None,
) -> None:
    preflight_gzip_archive(archive_path)
    archive_size = os.stat(archive_path, follow_symlinks=False).st_size
    expanded = 0
    rollback = 0
    extracted_entries = 0
    collision_entries = 0
    stage_filesystem = os.statvfs(stage)
    stage_path = nearest_existing_path(stage)

    def allocated(size: int, block_size: int) -> int:
        return max(block_size, ((size + block_size - 1) // block_size) * block_size)

    def archive_metadata_bytes(info: tarfile.TarInfo) -> int:
        return sum(len(key.encode("utf-8", "surrogateescape")) +
                   len(value.encode("utf-8", "surrogateescape")) + 256
                   for key, value in info.pax_headers.items())

    def filesystem_metadata_bytes(path: str) -> int:
        total = 0
        for name in os.listxattr(path, follow_symlinks=False):
            total += len(os.fsencode(name)) + len(os.getxattr(path, name, follow_symlinks=False)) + 256
        return total

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for info in archive:
                extracted_entries += 1
                if info.isfile():
                    expanded += allocated(info.size + archive_metadata_bytes(info), max(1, stage_filesystem.f_frsize))
                else:
                    expanded += allocated(archive_metadata_bytes(info), max(1, stage_filesystem.f_frsize))
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
                    rollback += allocated(info.st_size + filesystem_metadata_bytes(os.path.join("/", os.fsdecode(encoded))), max(1, stage_filesystem.f_frsize))
                else:
                    rollback += allocated(filesystem_metadata_bytes(os.path.join("/", os.fsdecode(encoded))), max(1, stage_filesystem.f_frsize))
            rollback += collision_entries * 1024 + 10240
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
                if name == ROOTLESS_GRAPHROOT_MEMBER:
                    if rootless_context is None:
                        fail("cannot estimate an unverified rootless graphroot restore")
                    with tarfile.open(archive_path, "r:gz") as outer:
                        nested_stream = outer.extractfile(info)
                        if nested_stream is None:
                            fail("cannot estimate rootless graphroot restore size")
                        preflight_tar_stream(nested_stream)
                        with tarfile.open(fileobj=nested_stream, mode="r:") as nested:
                            graphroot = str(rootless_context["graphroot"])
                            prefix = posixpath.basename(graphroot.rstrip("/"))
                            for nested_info in nested:
                                nested_name = clean_member_name(nested_info.name)
                                if nested_name != prefix and not nested_name.startswith(prefix + "/"):
                                    fail("rootless archive contains a path outside its graphroot")
                                relative = nested_name[len(prefix):].lstrip("/")
                                target = graphroot if not relative else os.path.join(graphroot, *relative.split("/"))
                                nested_size = nested_info.size if nested_info.isfile() else 0
                                charge_tree(target.lstrip("/"), nested_size + archive_metadata_bytes(nested_info))
                    continue
                size = (info.size if info.isfile() else 0) + archive_metadata_bytes(info)
                if info.islnk():
                    target = archive_members.get(clean_member_name(info.linkname))
                    size = (target.size if target is not None and target.isfile() else 0) + archive_metadata_bytes(info)
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
                    charge("/" + name, (info.st_size if stat.S_ISREG(info.st_mode) else 0) + filesystem_metadata_bytes(os.path.join("/", name)))
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
    if sys.argv[1:2] == ["backup-space-check"]:
        if len(sys.argv) < 6:
            raise SystemExit(2)
        archive_path, stage, graphroot = sys.argv[2:5]
        rest = sys.argv[5:]
        exclude_path = None
        if "--exclude-models" in rest:
            index = rest.index("--exclude-models")
            if index + 1 >= len(rest):
                raise SystemExit(2)
            exclude_path = rest[index + 1]
            del rest[index:index + 2]
        backup_space_check(archive_path, stage, graphroot, rest, exclude_path)
        return
    if sys.argv[1:2] == ["graphroot-rename"]:
        if len(sys.argv) != 4:
            raise SystemExit(2)
        rename_graphroot_noreplace(sys.argv[2], sys.argv[3])
        return
    if sys.argv[1:2] == ["graphroot-rename-expected"]:
        if len(sys.argv) != 6:
            raise SystemExit(2)
        rename_graphroot_noreplace(sys.argv[2], sys.argv[3], (int(sys.argv[4]), int(sys.argv[5])))
        return
    if sys.argv[1:2] == ["graphroot-create"]:
        if len(sys.argv) != 5:
            raise SystemExit(2)
        create_graphroot_noreplace(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        return
    if sys.argv[1:2] == ["graphroot-remove"]:
        if len(sys.argv) != 5:
            raise SystemExit(2)
        remove_graphroot_nofollow(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        return
    if sys.argv[1:2] == ["graphroot-check"]:
        if len(sys.argv) < 7:
            raise SystemExit(2)
        validate_graphroot_path(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6:])
        return
    if sys.argv[1:2] == ["stage-check"]:
        if len(sys.argv) != 3:
            raise SystemExit(2)
        stage_check(sys.argv[2])
        return
    if sys.argv[1:2] == ["sync-staging-snapshot"]:
        if len(sys.argv) != 4:
            raise SystemExit(2)
        sync_staging_snapshot(sys.argv[2], sys.argv[3])
        return
    if sys.argv[1:2] == ["restore-marker-check"]:
        if len(sys.argv) != 2:
            raise SystemExit(2)
        check_transaction_marker()
        return
    if sys.argv[1:2] == ["restore-marker-create"]:
        if len(sys.argv) != 5:
            raise SystemExit(2)
        create_transaction_marker(sys.argv[2], sys.argv[3], sys.argv[4])
        return
    if sys.argv[1:2] == ["restore-marker-clear"]:
        if len(sys.argv) != 2:
            raise SystemExit(2)
        clear_transaction_marker()
        return
    if sys.argv[1:2] == ["space-check"]:
        if len(sys.argv) < 4:
            raise SystemExit(2)
        rest = sys.argv[4:]
        rootless_context = None
        if "--rootless-context" in rest:
            index = rest.index("--rootless-context")
            if index + 1 >= len(rest):
                raise SystemExit(2)
            rootless_context = read_rootless_context(rest[index + 1])
            del rest[index:index + 2]
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
        space_check(sys.argv[2], sys.argv[3], collision_file, destinations, staged=staged, rootless_context=rootless_context)
        return
    if len(sys.argv) < 4 or sys.argv[1] not in {"validate", "validate-created", "members0", "collisions0", "destinations", "skip-links0", "unit-trees0", "rollback-new", "copy-source", "rootless-present", "sync-destinations"}:
        raise SystemExit(2)
    mode, archive, config = sys.argv[1:4]
    rest = sys.argv[4:]
    rootless_context = None
    if "--rootless-context" in rest:
        index = rest.index("--rootless-context")
        if index + 1 >= len(rest):
            raise SystemExit(2)
        rootless_context = read_rootless_context(rest[index + 1])
        del rest[index:index + 2]
    if mode == "copy-source":
        if len(rest) < 1:
            raise SystemExit(2)
        copy_source(archive, rest[-1])
        return
    if mode == "sync-destinations":
        sync_restore_filesystems(archive, config, rest, rootless_context)
        return
    if mode == "rollback-new":
        if len(rest) < 3:
            raise SystemExit(2)
        raise SystemExit(rollback_new(rest[-2], rest[-1], config, rest[:-2]))
    if mode == "rootless-present":
        roots = rest
        validate_archive(archive, config, roots, rootless_context=rootless_context)
        with tarfile.open(archive, "r:gz") as source:
            present = any(clean_member_name(info.name) == ROOTLESS_GRAPHROOT_MEMBER for info in source)
        print("1" if present else "0")
        return
    roots = rest[:-3] if mode == "unit-trees0" else rest[:-1] if mode in {"destinations", "skip-links0"} else rest
    names = validate_archive(
        archive,
        config,
        roots,
        require_root_config=mode != "validate-created" or os.geteuid() == 0,
        rootless_context=rootless_context,
    )
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
        for name in unit_trees(archive, rest[-3], config, roots, rest[-2:], rootless_context):
            sys.stdout.buffer.write(os.fsencode(name) + b"\0")
    if mode in {"members0", "collisions0"}:
        write_names(names, mode, config, roots)


if __name__ == "__main__":
    main()
