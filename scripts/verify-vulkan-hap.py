#!/usr/bin/env python3
"""Verify build/package evidence for OHOS Vulkan; does not claim device validation."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hap", type=Path)
    parser.add_argument("--core-build", type=Path, default=Path.home() / ".cache/hps2-build-vulkan")
    parser.add_argument("--native-library", type=Path, default=Path(__file__).resolve().parents[1] /
                        "app-hps2/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libhps2core.so")
    args = parser.parse_args()
    with zipfile.ZipFile(args.hap) as package:
        # The native core and its C++ runtime are the only packaged shared libraries.
        # Build staging can contain Finder/sync copies such as "libhps2core 2.so".
        # Reject these rather than silently shipping another complete emulator core.
        expected_libraries = {"libs/arm64-v8a/libhps2core.so", "libs/arm64-v8a/libc++_shared.so"}
        libraries = {name for name in package.namelist() if name.startswith("libs/") and name.endswith(".so")}
        if libraries != expected_libraries:
            parser.exit(1, "FAIL: unexpected native library inventory: " + ", ".join(sorted(libraries)) + "\n")
        binary = package.read("libs/arm64-v8a/libhps2core.so")
        if binary[:4] != b"\x7fELF" or int.from_bytes(binary[18:20], "little") != 183:
            parser.exit(1, "FAIL: package native library is not AArch64 ELF\n")
        for marker in [b"vkCreateSurfaceOHOS", b"VK_OHOS_surface", b"Vulkan OHOS: surface created successfully."]:
            if marker not in binary:
                parser.exit(1, "FAIL: missing native Vulkan marker " + marker.decode() + "\n")
        for shader in ["convert", "present", "interlace", "merge", "shadeboost", "tfx", "imgui"]:
            name = "resources/rawfile/resources/shaders/vulkan/" + shader + ".glsl"
            if name not in package.namelist():
                parser.exit(1, "FAIL: missing shader asset " + name + "\n")
    cache = (args.core_build / "CMakeCache.txt").read_text()
    if "USE_VULKAN:BOOL=ON" not in cache.splitlines():
        parser.exit(1, "FAIL: selected core was not configured with Vulkan\n")
    gs_target = "PCSX2_LTO" if "LTO_PCSX2_CORE:BOOL=ON" in cache.splitlines() else "PCSX2"
    target_dir = args.core_build / "pcsx2/CMakeFiles" / (gs_target + ".dir")
    objects = target_dir / "GS/Renderers/Vulkan"
    for obj in ["GSDeviceVK.cpp.o", "VKLoader.cpp.o", "VKShaderCache.cpp.o", "VKSwapChain.cpp.o"]:
        if not (objects / obj).is_file():
            parser.exit(1, "FAIL: missing actual Vulkan object " + obj + "\n")
    flags = (target_dir / "flags.make").read_text()
    if "-DARMSX2_LINK_SHADERC" not in flags:
        parser.exit(1, "FAIL: shaderc direct-call mode was not compiled\n")
    sdk = Path("/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin")
    with tempfile.TemporaryDirectory(prefix="hps2-vulkan-check-") as temp:
        library = Path(temp) / "libhps2core.so"
        library.write_bytes(binary)
        dynamic = subprocess.check_output([str(sdk / "llvm-readelf"), "-d", str(library)], text=True)
        undefined = subprocess.check_output([str(sdk / "llvm-nm"), "--dynamic", "--undefined-only", str(library)], text=True)
        if "shaderc_shared" in dynamic or any("shaderc_" in line for line in undefined.splitlines()):
            parser.exit(1, "FAIL: shaderc is missing or depends on a runtime shared library\n")
        symbols = subprocess.check_output([str(sdk / "llvm-nm"), "--defined-only", str(args.native_library)], text=True)
        names = {line.split()[-1] for line in symbols.splitlines() if line.split()}
        if not {"shaderc_compiler_initialize", "shaderc_compile_into_spv"}.issubset(names):
            parser.exit(1, "FAIL: native library has no statically defined shader compiler\n")
        # Shaderc symbols are hidden in the stripped HAP. Match its executable code
        # to the unstripped library whose actual definitions were checked above.
        package_text = Path(temp) / "package.text"
        build_text = Path(temp) / "build.text"
        for source, dest in [(library, package_text), (args.native_library, build_text)]:
            subprocess.run([str(sdk / "llvm-objcopy"), "--dump-section", f".text={dest}",
                            str(source), str(Path(temp) / (dest.name + ".elf"))], check=True)
        if package_text.read_bytes() != build_text.read_bytes():
            parser.exit(1, "FAIL: HAP executable code differs from the verified native library\n")
    print("PASS: AArch64 ELF, OHOS WSI, shader assets, Vulkan objects, static shaderc linkage")
    print("HAP SHA256:", hashlib.sha256(args.hap.read_bytes()).hexdigest())
    print("native SHA256:", hashlib.sha256(binary).hexdigest())
    print("Device surface/swapchain, shader execution, rendering and performance remain unverified.")


if __name__ == "__main__":
    main()
