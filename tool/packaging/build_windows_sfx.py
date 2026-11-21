#!/usr/bin/env python3
"""Packages a Flutter Windows Release directory into a single-file LZMS SFX executable."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

CRT_DLLS = (
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
)
PE_MACHINE = {"x64": 0x8664, "arm64": 0xAA64}


def host_arch_name() -> str:
    m = platform.machine().lower()
    return "arm64" if m in ("arm64", "aarch64") else "x64"


def find_vs_installations() -> list[Path]:
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    vswhere = Path(pf86) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    installs: list[Path] = []
    if vswhere.is_file():
        out = subprocess.check_output(
            [str(vswhere), "-products", "*", "-sort", "-format", "json"],
            text=True,
            encoding="utf-8",
        )
        for item in json.loads(out or "[]"):
            p = Path(item.get("installationPath", ""))
            if (p / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat").is_file():
                installs.append(p)
    vs_env = os.environ.get("VSINSTALLDIR")
    if vs_env:
        p = Path(vs_env.rstrip("\\/"))
        if p not in installs and (p / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat").is_file():
            installs.insert(0, p)
    if not installs:
        raise FileNotFoundError("Could not locate Visual Studio with VC\\Auxiliary\\Build\\vcvarsall.bat")
    return installs


def pick_vcvars(installs: list[Path], host: str, target: str) -> tuple[Path, Path, str]:
    candidates = [("arm64", "arm64", "arm64"), ("x64", "arm64", "x64_arm64")] if host == "arm64" and target == "arm64" else [
        (host, target, target if host == target else f"{host}_{target}")
    ]
    for vs in installs:
        msvc_root = vs / "VC" / "Tools" / "MSVC"
        for h, t, arg in candidates:
            if any((v / "bin" / f"Host{h}" / t / "cl.exe").is_file() for v in sorted(msvc_root.glob("*"), reverse=True)):
                return vs, vs / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat", arg
    return installs[0], installs[0] / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat", target if host == target else f"{host}_{target}"


def find_vc_redist_dlls(vs_dir: Path, arch: str) -> list[Path]:
    roots: list[Path] = []
    if os.environ.get("VCToolsRedistDir"):
        roots.append(Path(os.environ["VCToolsRedistDir"]))
    redist_base = vs_dir / "VC" / "Redist" / "MSVC"
    if redist_base.is_dir():
        roots.extend(sorted(redist_base.iterdir(), reverse=True))
    for ver_dir in roots:
        for crt in sorted((ver_dir / arch).glob("Microsoft.VC*.CRT"), reverse=True):
            if crt.is_dir():
                return [crt / n for n in CRT_DLLS if (crt / n).is_file()]
    return []


def read_pubspec_version(repo: Path) -> str:
    text = (repo / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([^\s+#]+)", text, re.MULTILINE)
    if not m:
        raise ValueError("Could not parse version from pubspec.yaml")
    return m.group(1).strip()


def run_vcvars(vcvarsall: Path, vcvars_arg: str, cmd: str, cwd: Path) -> None:
    bat = cwd / "_vc_step.cmd"
    bat.write_text(f'@echo off\r\ncall "{vcvarsall}" {vcvars_arg} >nul\r\nif errorlevel 1 exit /b %errorlevel%\r\n{cmd}\r\n', encoding="utf-8")
    try:
        subprocess.run(["cmd.exe", "/d", "/c", str(bat)], cwd=str(cwd), check=True)
    finally:
        bat.unlink(missing_ok=True)


def compute_tree_tag(release_dir: Path, app_version: str) -> str:
    h = hashlib.sha256()
    for p in sorted(release_dir.rglob("*")):
        if p.is_file():
            h.update(p.relative_to(release_dir).as_posix().encode("utf-8"))
            h.update(str(p.stat().st_size).encode("utf-8"))
            h.update(p.read_bytes()[:4096])
    return f"{app_version}-{h.hexdigest()[:8]}"


def verify_pe_machine(exe_path: Path, arch: str) -> None:
    data = exe_path.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError(f"Invalid DOS header in {exe_path}")
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        raise ValueError(f"Invalid PE signature in {exe_path}")
    machine = struct.unpack_from("<H", data, pe_off + 4)[0]
    expected = PE_MACHINE[arch]
    if machine != expected:
        raise ValueError(f"PE machine mismatch for {exe_path}: got 0x{machine:04x}, expected 0x{expected:04x}")


def build_rc(icon_path: Path, ver_file: Path, payload_lzms: Path, app_version: str, orig_name: str) -> str:
    ver_num = app_version.split("-")[0].split("+")[0]
    parts = [p if p.isdigit() else "0" for p in ver_num.split(".")] + ["0", "0", "0", "0"]
    v4 = ",".join(parts[:4])
    return f'''#include <winver.h>
1 ICON "{icon_path.as_posix()}"
101 RCDATA "{ver_file.as_posix()}"
102 RCDATA "{payload_lzms.as_posix()}"
VS_VERSION_INFO VERSIONINFO
 FILEVERSION {v4}
 PRODUCTVERSION {v4}
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0x0L
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_APP
 FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "Run My AI"
            VALUE "FileDescription", "Run My AI"
            VALUE "FileVersion", "{app_version}"
            VALUE "InternalName", "runmyai.exe"
            VALUE "OriginalFilename", "{orig_name}"
            VALUE "ProductName", "Run My AI"
            VALUE "ProductVersion", "{app_version}"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
'''


def main() -> int:
    pkg_dir = Path(__file__).resolve().parent
    default_repo = pkg_dir.parents[1]
    parser = argparse.ArgumentParser(description="Package Run My AI Windows Release as a single-file SFX exe.")
    parser.add_argument("--repo", type=Path, default=default_repo)
    parser.add_argument("--arch", choices=("x64", "arm64"), default=host_arch_name())
    parser.add_argument("--version", default="")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--check-env", action="store_true", help="Verify VS/CRT paths and exit.")
    args = parser.parse_args()

    repo = args.repo.resolve()
    version = (args.version or read_pubspec_version(repo)).lstrip("v")
    out_exe = (args.out or (repo / "dist" / f"RunMyAI-windows-{args.arch}.exe")).resolve()

    host = host_arch_name()
    installs = find_vs_installations()
    vs_host, vcvars_host_bat, vcvars_host_arg = pick_vcvars(installs, host, host)
    vs_tgt, vcvars_tgt_bat, vcvars_tgt_arg = pick_vcvars(installs, host, args.arch)
    crt_dlls = find_vc_redist_dlls(vs_tgt, args.arch)
    if args.check_env:
        print(f"version={version} host={host} target={args.arch}")
        print(f"vs_host={vs_host} ({vcvars_host_arg})")
        print(f"vs_target={vs_tgt} ({vcvars_tgt_arg})")
        print(f"crt_dlls={[d.name for d in crt_dlls]}")
        return 0 if crt_dlls else 1

    release_dir = repo / "build" / "windows" / args.arch / "runner" / "Release"
    if not (release_dir / "runmyai.exe").is_file():
        raise FileNotFoundError(f"Missing Flutter release dir: {release_dir}")
    if not crt_dlls:
        raise FileNotFoundError(f"Could not find VC CRT redistributable DLLs for {args.arch} under {vs_tgt}")

    with tempfile.TemporaryDirectory(prefix="rma-win-sfx-") as tmp:
        work = Path(tmp)
        stage = work / "stage"
        shutil.copytree(release_dir, stage)
        for dll in crt_dlls:
            dst = stage / dll.name
            if not dst.is_file():
                shutil.copy2(dll, dst)

        tag = compute_tree_tag(stage, version)
        ver_file = work / "version_tag.txt"
        ver_file.write_text(tag, encoding="utf-8", newline="")

        pack_exe = work / "pack_blob.exe"
        run_vcvars(
            vcvars_host_bat,
            vcvars_host_arg,
            f'cl /nologo /O2 /EHsc /std:c++17 "{pkg_dir / "pack_blob.cpp"}" /Fe:"{pack_exe}" /link cabinet.lib',
            work,
        )
        payload_lzms = work / "payload.lzms"
        subprocess.run([str(pack_exe), str(stage), str(payload_lzms)], cwd=str(work), check=True)

        rc_path = work / "sfx.rc"
        icon_path = repo / "windows" / "runner" / "resources" / "app_icon.ico"
        rc_path.write_text(build_rc(icon_path, ver_file, payload_lzms, version, out_exe.name), encoding="utf-8")
        res_path = work / "sfx.res"
        out_exe.parent.mkdir(parents=True, exist_ok=True)
        run_vcvars(vcvars_tgt_bat, vcvars_tgt_arg, f'rc /nologo /fo "{res_path}" "{rc_path}"', work)
        run_vcvars(
            vcvars_tgt_bat,
            vcvars_tgt_arg,
            f'cl /nologo /O2 /MT /EHsc /DUNICODE /D_UNICODE /std:c++17 "{pkg_dir / "sfx_stub.cpp"}" "{res_path}" '
            f'/Fe:"{out_exe}" /link /SUBSYSTEM:WINDOWS cabinet.lib shell32.lib ole32.lib user32.lib',
            work,
        )

    verify_pe_machine(out_exe, args.arch)
    print(f"Built single-file Windows SFX: {out_exe} ({out_exe.stat().st_size} bytes), tag={tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
