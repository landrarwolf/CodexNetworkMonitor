#!/usr/bin/env python3
"""Check tracked public files without printing matched private content.

PNG pixels are deliberately not inspected. A successful result still requires
human review of screenshots, file names, documentation, and Git history.
Only Python's standard library and a local Git installation are used.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_PRIVATE_CHUNKS = {b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"tIME"}
MAX_PUBLIC_BYTES = 8 * 1024 * 1024
PRIVATE_HOME = re.compile(re.escape("/" + "Users" + "/"))
TOKEN_PATTERNS = (
    re.compile(r"\bsk-(?:proj-|svcacct-|ant-)?[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{50,}\b"),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    re.compile(
        r"(?i)\b(?:api[_-]?key|access[_-]?token|secret[_-]?key)"
        r"\s*[:=]\s*[\"']?[A-Za-z0-9_./+=-]{32,}"
    ),
)
PEM_PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----")


@dataclass(frozen=True, order=True)
class Finding:
    file: str
    category: str


class CheckError(Exception):
    """A safe diagnostic: never includes Git output or file contents."""


def git(root: Path, *arguments: str) -> subprocess.CompletedProcess:
    environment = os.environ.copy()
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        return subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "-C", str(root), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
            check=False,
        )
    except OSError as error:
        raise CheckError("Git is unavailable; install Git before checking public files.") from error


def path_category(name: str) -> str | None:
    path = PurePosixPath(name)
    parts = [part.lower() for part in path.parts]
    leaf = parts[-1] if parts else ""
    if path.is_absolute() or ".." in path.parts:
        return "unsafe repository path"
    if any(part in {"work", "dist", ".build", ".swiftpm"} for part in parts):
        return "private work directory or build output"
    if any(part.endswith(".app") for part in parts) or leaf.endswith(
        (".zip", ".dmg", ".pkg", ".tgz", ".tar", ".tar.gz", ".7z",
         ".exe", ".dll", ".dylib", ".so", ".a", ".o", ".bin")
    ):
        return "archive, application, or compiled binary"
    if (
        any(part in {".ssh", ".aws", ".gnupg"} for part in parts)
        or leaf in {"auth.json", "credentials", "credentials.json", ".netrc",
                    ".git-credentials", ".npmrc", ".pypirc", "id_rsa", "id_dsa",
                    "id_ecdsa", "id_ed25519"}
        or leaf == ".env" or leaf.startswith(".env.")
    ):
        return "credential file or directory"
    if (
        leaf == "history.jsonl"
        or leaf.endswith(".log")
        or leaf.endswith(".jsonl") and (
            leaf.startswith(("rollout-", "session-"))
            or any(part in {"sessions", "session_logs", "logs", "rollout_summaries"} for part in parts)
        )
    ):
        return "runtime history or raw session log"
    if leaf.endswith(".png") and path.parts[:2] != ("docs", "screenshots"):
        return "PNG outside docs/screenshots"
    return None


def png_categories(data: bytes) -> set[str]:
    """Inspect container chunks and CRCs, never pixel or EXIF contents."""
    if not data.startswith(PNG_SIGNATURE):
        return {"invalid PNG container"}
    categories: set[str] = set()
    position = len(PNG_SIGNATURE)
    first = True
    saw_image_data = False
    while position < len(data):
        if len(data) - position < 12:
            return categories | {"invalid PNG container"}
        length = struct.unpack_from(">I", data, position)[0]
        end = position + length + 12
        if end > len(data):
            return categories | {"invalid PNG container"}
        kind = data[position + 4:position + 8]
        payload = data[position + 8:end - 4]
        expected_crc = struct.unpack_from(">I", data, end - 4)[0]
        if re.fullmatch(rb"[A-Za-z]{4}", kind) is None:
            return categories | {"invalid PNG container"}
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            return categories | {"invalid PNG container"}
        if first and (kind != b"IHDR" or length != 13):
            return categories | {"invalid PNG container"}
        first = False
        if kind in PNG_PRIVATE_CHUNKS:
            categories.add("PNG contains disclosable metadata")
        if kind == b"IDAT":
            saw_image_data = True
        position = end
        if kind == b"IEND":
            if length != 0 or not saw_image_data or position != len(data):
                categories.add("invalid PNG container or trailing data")
            return categories
    return categories | {"invalid PNG container"}


def content_categories(name: str, data: bytes) -> set[str]:
    if name.lower().endswith(".png"):
        return png_categories(data)
    if b"\x00" in data:
        return {"unsupported binary content"}
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return {"unsupported binary content"}
    categories: set[str] = set()
    if PRIVATE_HOME.search(text):
        categories.add("private absolute home path")
    if any(pattern.search(text) for pattern in TOKEN_PATTERNS):
        categories.add("credential-like API or account token")
    if PEM_PRIVATE_KEY.search(text):
        categories.add("PEM private key")
    return categories


def scan(root: Path) -> tuple[list[Finding], int]:
    root = root.resolve()
    location = git(root, "rev-parse", "--show-toplevel")
    if location.returncode != 0:
        raise CheckError("This project has no Git repository. Run git init and stage the public files first.")
    try:
        actual_root = Path(os.fsdecode(location.stdout.rstrip(b"\r\n"))).resolve()
    except (OSError, ValueError) as error:
        raise CheckError("Cannot identify this project's Git root.") from error
    if actual_root != root:
        raise CheckError("The project is not a Git repository root; initialize Git here to avoid scanning a parent project.")
    listed = git(root, "ls-files", "-z")
    if listed.returncode != 0:
        raise CheckError("Cannot list tracked public files.")
    names = sorted({os.fsdecode(name) for name in listed.stdout.split(b"\x00") if name})
    if not names:
        raise CheckError("No tracked or staged files were found. Stage the intended public files first.")
    findings: set[Finding] = set()
    for name in names:
        prohibited = path_category(name)
        if prohibited:
            findings.add(Finding(name, prohibited))
            continue  # Do not open credential, session-log, work, or build paths.
        path = root / name
        try:
            path.resolve().relative_to(root)
            mode = path.lstat().st_mode
        except ValueError:
            findings.add(Finding(name, "path resolves outside repository"))
            continue
        except OSError:
            mode = None
        if mode is not None and not stat.S_ISREG(mode):
            findings.add(Finding(name, "symbolic link or non-regular file"))
            continue
        # Check the index as well: an unstaged redaction must not hide a staged secret.
        staged_size = git(root, "cat-file", "-s", ":" + name)
        try:
            size = int(staged_size.stdout) if staged_size.returncode == 0 else -1
        except ValueError:
            size = -1
        if size < 0:
            findings.add(Finding(name, "cannot inspect staged content"))
            continue
        if size > MAX_PUBLIC_BYTES:
            findings.add(Finding(name, "public file exceeds inspection size limit"))
            continue
        staged = git(root, "show", ":" + name)
        if staged.returncode != 0:
            findings.add(Finding(name, "cannot inspect staged content"))
            continue
        for category in content_categories(name, staged.stdout):
            findings.add(Finding(name, category))
        if mode is None:
            findings.add(Finding(name, "tracked file is missing from working tree"))
            continue
        try:
            if path.stat().st_size > MAX_PUBLIC_BYTES:
                findings.add(Finding(name, "public file exceeds inspection size limit"))
                continue
            working = path.read_bytes()
        except OSError:
            findings.add(Finding(name, "cannot inspect working-tree content"))
            continue
        if working != staged.stdout:
            for category in content_categories(name, working):
                findings.add(Finding(name, category))
    return sorted(findings), len(names)


def safe_file_name(name: str) -> str:
    for pattern in TOKEN_PATTERNS:
        name = pattern.sub("[redacted-token]", name)
    name = PEM_PRIVATE_KEY.sub("[redacted-private-key]", name)
    return json.dumps(name, ensure_ascii=True)


def report(findings: list[Finding], count: int) -> int:
    if findings:
        print(f"Public-file check failed: {len(findings)} finding(s) across {count} tracked/staged file(s).")
        for finding in findings:
            print(f"- {safe_file_name(finding.file)}: {finding.category}")
    else:
        print(f"Public-file check passed for {count} tracked/staged file(s), including index and working tree.")
    print("This cannot replace human privacy review. Inspect screenshot pixels, file names, documentation, and Git history before publishing.")
    return 1 if findings else 0


def self_test() -> int:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    def png(metadata: bytes | None = None) -> bytes:
        header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
        extra = chunk(metadata, b"synthetic-marker") if metadata else b""
        return (PNG_SIGNATURE + chunk(b"IHDR", header) + chunk(b"sRGB", b"\x00")
                + extra + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00\xff")) + chunk(b"IEND", b""))

    api_marker = "sk-" + "A" * 40
    github_marker = "ghp_" + "B" * 36
    private_path = "/" + "Users" + "/" + "synthetic-user/private.txt"
    private_key = "-----BEGIN " + "PRIVATE KEY-----\n" + "A" * 64
    cases: list[tuple[str, dict[str, bytes], str | None]] = [
        ("synthetic source and color-only PNG", {
            "source.swift": b'let sample = "private-prompt-example-token example.invalid localhost:7890"\n',
            "docs/screenshots/demo.png": png(),
            "scripts/check_public.py": Path(__file__).read_bytes(),
        }, None),
        ("API token", {"source.swift": api_marker.encode()}, "credential-like API or account token"),
        ("GitHub token", {"README.md": github_marker.encode()}, "credential-like API or account token"),
        ("private home path", {"README.md": private_path.encode()}, "private absolute home path"),
        ("history path", {"history.jsonl": b"synthetic only"}, "runtime history or raw session log"),
        ("credential path", {"auth.json": b"synthetic only"}, "credential file or directory"),
        ("environment path", {".env": b"synthetic only"}, "credential file or directory"),
        ("raw session path", {"sessions/rollout-synthetic.jsonl": b"synthetic only"}, "runtime history or raw session log"),
        ("build path", {"dist/demo.zip": b"synthetic only"}, "private work directory or build output"),
        ("application archive", {"demo.zip": b"synthetic only"}, "archive, application, or compiled binary"),
        ("PEM key", {"source.swift": private_key.encode()}, "PEM private key"),
        ("PNG location", {"demo.png": png()}, "PNG outside docs/screenshots"),
        ("PNG trailing data", {"docs/screenshots/demo.png": png() + b"synthetic marker"}, "invalid PNG container or trailing data"),
    ]
    for kind in sorted(PNG_PRIVATE_CHUNKS):
        cases.append(("PNG metadata " + kind.decode("ascii"), {"docs/screenshots/demo.png": png(kind)}, "PNG contains disclosable metadata"))
    passed = 0
    with tempfile.TemporaryDirectory(prefix="codex-monitor-public-check-") as temporary:
        base = Path(temporary)
        for number, (label, files, expected) in enumerate(cases):
            root = base / str(number)
            root.mkdir()
            if git(root, "init", "--quiet").returncode != 0:
                raise CheckError("Cannot create a temporary Git fixture for the self-test.")
            for name, data in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            if git(root, "add", "--all").returncode != 0:
                raise CheckError("Cannot stage a temporary self-test fixture.")
            findings, count = scan(root)
            ok = not findings if expected is None else any(f.category == expected for f in findings)
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                report(findings, count)
            if any(marker in captured.getvalue() for marker in (api_marker, github_marker, private_path, private_key)):
                ok = False
            if not ok:
                print("Self-test failed: " + label + ". No matched content is printed.")
                return 1
            passed += 1
        # A redacted working tree must not conceal a secret still staged in Git.
        root = base / "staged-content"
        root.mkdir()
        git(root, "init", "--quiet")
        (root / "README.md").write_text(api_marker, encoding="utf-8")
        git(root, "add", "--all")
        (root / "README.md").write_text("redacted", encoding="utf-8")
        findings, _ = scan(root)
        if not any(f.category == "credential-like API or account token" for f in findings):
            print("Self-test failed: staged content. No matched content is printed.")
            return 1
        passed += 1
        not_a_repo = base / "no-repository"
        not_a_repo.mkdir()
        try:
            scan(not_a_repo)
        except CheckError:
            passed += 1
        else:
            print("Self-test failed: missing Git repository.")
            return 1
    print(f"Self-test passed: {passed} synthetic cases. No real credentials, account data, network access, or user logs were used.")
    print("Automated checks cannot replace human privacy review of screenshots and Git history.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="run synthetic temporary-Git fixtures only")
    arguments = parser.parse_args()
    try:
        if arguments.self_test:
            return self_test()
        return report(*scan(Path(__file__).resolve().parent.parent))
    except CheckError as error:
        print("Public-file check error: " + str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError):
        print("Public-file check error: cannot safely inspect project files; no file contents are printed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
