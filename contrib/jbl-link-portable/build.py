#!/usr/bin/env python3
"""Build the ARMv7 Fluent Bit plugin locally; no device access or installation."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--clang")
    parser.add_argument("--lld")
    args = parser.parse_args()
    clang = args.clang or shutil.which("clang", path="/opt/homebrew/opt/llvm/bin:" + os.environ.get("PATH", ""))
    linker = args.lld or shutil.which("ld.lld")
    env = dict(os.environ)
    link_prefix = []
    if not linker:
        toolchain = Path.home() / ".rustup/toolchains/stable-aarch64-apple-darwin"
        candidate = toolchain / "lib/rustlib/aarch64-apple-darwin/bin/rust-lld"
        if candidate.is_file():
            linker = str(candidate)
            link_prefix = ["-flavor", "gnu"]
            env["DYLD_LIBRARY_PATH"] = str(toolchain / "lib")
    if not clang or not linker:
        raise RuntimeError("Specify an ARM-capable clang and ELF lld; nothing is installed automatically")
    destination = ROOT / "build"
    if args.probe:
        destination /= "probe"
    destination.mkdir(parents=True, exist_ok=True)
    obj = destination / "fluent_bootstrap.o"
    output = destination / "flb-in_jbl_bootstrap.so"
    command = [clang, "--target=armv7-linux-gnueabihf", "-mfpu=vfpv3-d16", "-mfloat-abi=hard",
               "-fPIC", "-O2", "-c", str(ROOT / "fluent_bootstrap.c"), "-o", str(obj)]
    if args.probe:
        command.append("-DJBL_PROBE")
    subprocess.run(command, check=True, timeout=30)
    subprocess.run([linker] + link_prefix + ["-shared", "-m", "armelf_linux_eabi", str(obj), "-o", str(output)],
                   check=True, env=env, timeout=30)
    print(f"BUILT {output.name}: {len(output.read_bytes())} bytes SHA256={hashlib.sha256(output.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
