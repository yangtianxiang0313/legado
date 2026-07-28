#!/usr/bin/env python3
"""Isolated standard-library runner for SwiftPM manifest inspection."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from typing import Mapping, Optional


def dump_package(
    package_root: Path,
    *,
    cwd: Path,
    timeout: int = 60,
    environment: Optional[Mapping[str, str]] = None,
) -> subprocess.CompletedProcess:
    """Run dump-package with private caches and no nested SwiftPM sandbox."""
    source_environment = os.environ if environment is None else environment
    child_environment = dict(source_environment)
    with tempfile.TemporaryDirectory(prefix="legado-swiftpm-manifest-") as directory:
        isolated_root = Path(directory)
        cache_path = isolated_root / "cache"
        config_path = isolated_root / "config"
        security_path = isolated_root / "security"
        scratch_path = isolated_root / "scratch"
        module_cache_path = isolated_root / "module-cache"
        for path in (
            cache_path,
            config_path,
            security_path,
            scratch_path,
            module_cache_path,
        ):
            path.mkdir()
        child_environment.update(
            {
                "CLANG_MODULE_CACHE_PATH": str(module_cache_path),
                "SWIFTPM_MODULECACHE_OVERRIDE": str(module_cache_path),
            }
        )
        command = [
            "swift",
            "package",
            "--package-path",
            str(package_root),
            "--disable-sandbox",
            "--cache-path",
            str(cache_path),
            "--config-path",
            str(config_path),
            "--security-path",
            str(security_path),
            "--scratch-path",
            str(scratch_path),
            "dump-package",
        ]
        return subprocess.run(
            command,
            cwd=str(cwd),
            env=child_environment,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
