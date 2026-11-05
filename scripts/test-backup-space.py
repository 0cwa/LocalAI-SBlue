#!/usr/bin/env python3
"""Regression tests for restore capacity checks across separate filesystems."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import shutil
import tempfile
import tarfile
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("backup_archive", ROOT / "lib/backup_archive.py")
assert SPEC is not None and SPEC.loader is not None
backup_archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup_archive)


def make_archive(path: Path, root_a: Path, root_b: Path) -> None:
    with tarfile.open(path, "w:gz") as archive:
        metadata = tarfile.TarInfo("metadata")
        metadata.size = 3
        archive.addfile(metadata, io.BytesIO(b"v=1"))
        for root, directory_name, child_name in (
            (root_a, "models", "model.bin"),
            (root_b, "cache", "cache.bin"),
        ):
            root_name = root.as_posix().lstrip("/")
            directory = tarfile.TarInfo(root_name)
            directory.type = tarfile.DIRTYPE
            archive.addfile(directory)
            nested_directory = tarfile.TarInfo(f"{root_name}/{directory_name}")
            nested_directory.type = tarfile.DIRTYPE
            archive.addfile(nested_directory)
            member = tarfile.TarInfo(f"{root_name}/{directory_name}/{child_name}")
            member.size = 128 * 1024
            archive.addfile(member, io.BytesIO(b"x" * member.size))


def run_case(
    *,
    free_a: int = 512 * 1024 * 1024,
    free_b: int,
    inodes_a: int = 1000,
    inodes_b: int,
    include_collision: bool = False,
) -> str:
    with tempfile.TemporaryDirectory(prefix="backup-space-test-") as temp:
        base = Path(temp)
        stage = base / "stage"
        root_a = base / "mount-a"
        root_b = base / "mount-b"
        stage.mkdir()
        root_a.mkdir()
        root_b.mkdir()
        archive = base / "backup.tar.gz"
        make_archive(archive, root_a, root_b)
        collision_file = None
        if include_collision:
            old_file = root_a / "old.bin"
            old_file.write_bytes(b"y" * (256 * 1024))
            collision_file = base / "collisions0"
            collision_file.write_bytes(os.fsencode(old_file.as_posix().lstrip("/")) + b"\0")
        disk_usage = shutil.disk_usage
        statvfs = os.statvfs

        def fake_statvfs(path: str | os.PathLike[str]) -> SimpleNamespace:
            candidate = Path(path)
            if candidate == root_a or root_a in candidate.parents:
                return SimpleNamespace(f_frsize=4096, f_fsid=101, f_files=10000, f_favail=inodes_a, f_bavail=free_a // 4096)
            if candidate == root_b or root_b in candidate.parents:
                return SimpleNamespace(f_frsize=4096, f_fsid=202, f_files=10000, f_favail=inodes_b, f_bavail=free_b // 4096)
            real = statvfs(path)
            return SimpleNamespace(
                f_frsize=real.f_frsize,
                f_fsid=getattr(real, "f_fsid", 0),
                f_files=real.f_files,
                f_favail=real.f_favail,
                f_bavail=real.f_bavail,
                f_blocks=real.f_blocks,
            )

        def fake_disk_usage(path: str | os.PathLike[str]) -> shutil._ntuple_diskusage:
            candidate = Path(path)
            if candidate == stage:
                return shutil._ntuple_diskusage(10**12, 0, 10**12)
            if candidate == root_a or root_a in candidate.parents:
                return shutil._ntuple_diskusage(10**12, 0, free_a)
            if candidate == root_b or root_b in candidate.parents:
                return shutil._ntuple_diskusage(10**12, 0, free_b)
            return disk_usage(path)

        os.statvfs = fake_statvfs
        shutil.disk_usage = fake_disk_usage
        error_output = io.StringIO()
        try:
            with contextlib.redirect_stderr(error_output):
                backup_archive.space_check(
                    str(archive),
                    str(stage),
                    str(collision_file) if collision_file else None,
                    [str(root_a), str(root_b)],
                )
        except SystemExit:
            return error_output.getvalue()
        finally:
            os.statvfs = statvfs
            shutil.disk_usage = disk_usage
        return ""


def main() -> None:
    enough = run_case(free_b=512 * 1024 * 1024, inodes_b=1000)
    assert not enough, enough
    low_data = run_case(free_b=64 * 1024 * 1024, inodes_b=1000)
    assert "insufficient free disk space on a restore destination filesystem" in low_data
    low_inodes = run_case(free_b=512 * 1024 * 1024, inodes_b=0)
    assert "insufficient free inodes on a restore destination filesystem" in low_inodes
    low_rollback = run_case(
        free_a=64 * 1024 * 1024 + 300 * 1024,
        free_b=512 * 1024 * 1024,
        inodes_b=1000,
        include_collision=True,
    )
    assert "insufficient free disk space on a restore destination filesystem" in low_rollback

    print("backup archive destination capacity tests passed")


if __name__ == "__main__":
    main()
