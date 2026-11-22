"""Run a packaged addon in an isolated LuaJIT state with an offline harness."""

from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import re
import struct
import sys
import zipfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
PROJECT_DIR = TEST_DIR.parent
SDK_READER = Path("tools") / "hd2_archive.py"
DEFAULT_DLL = Path(r"E:\Hellforge\HellForge\game\bin\lua51.dll")


def default_package() -> Path:
    version = (PROJECT_DIR / "VERSION").read_text(encoding="utf-8-sig").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("VERSION must contain major.minor.patch")
    package = PROJECT_DIR / "build" / f"FieldSampleDrops-{version}.zip"
    if not package.is_file():
        raise FileNotFoundError(f"{package} is missing. Run build.ps1 first.")
    return package


def default_sdk_dir() -> Path:
    local_sdk = PROJECT_DIR / ".tools" / "sdk"
    workspace_sdk = PROJECT_DIR.parent / ".tools" / "sdk"
    if not (local_sdk / SDK_READER).is_file() and (workspace_sdk / SDK_READER).is_file():
        return workspace_sdk
    return local_sdk


def read_addon(package: Path, sdk_dir: Path | None = None) -> tuple[bytes, str]:
    archive_tool = (sdk_dir if sdk_dir is not None else default_sdk_dir()) / SDK_READER
    if not archive_tool.is_file():
        raise FileNotFoundError(f"SDK archive reader not found at {archive_tool}. Pass --sdk-dir with the SDK root.")
    spec = importlib.util.spec_from_file_location("hd2_archive", archive_tool)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load SDK archive reader at {archive_tool}")
    archive = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(archive)

    with zipfile.ZipFile(package) as bundle:
        manifest = json.loads(bundle.read("hd2runtime.json"))
        name = manifest["resource"]
        key = (archive.LUA_TYPE, archive.resource_hash(name))
        resources = []
        for entry in bundle.namelist():
            if not entry.endswith("/" + archive.ARCHIVE_NAME):
                continue
            resource = archive.read_archive(bundle.read(entry)).get(key)
            if resource is not None:
                resources.append(resource[0])

    if len(resources) != 1:
        raise ValueError(f"expected one {name!r} resource, found {len(resources)}")
    chunk, = resources
    size, version = struct.unpack_from("<II", chunk)
    body = chunk[8:]
    if size != len(body) or version != 2:
        raise ValueError(f"invalid Lua resource header for {name}")
    if body.startswith(b"\x1b"):
        raise ValueError("the offline harness expects a Lua source chunk")
    return body, name


def run_lua(dll: Path, harness: Path, body: bytes, name: str) -> None:
    lua = ctypes.CDLL(str(dll.resolve(strict=True)))
    state = ctypes.c_void_p
    size = ctypes.c_size_t
    integer = ctypes.c_int
    signatures = {
        "luaL_newstate": (state, ()),
        "luaL_openlibs": (None, (state,)),
        "luaL_loadbuffer": (integer, (state, ctypes.c_char_p, size, ctypes.c_char_p)),
        "lua_pushlstring": (None, (state, ctypes.c_char_p, size)),
        "lua_pcall": (integer, (state, integer, integer, integer)),
        "lua_tolstring": (ctypes.c_void_p, (state, integer, ctypes.POINTER(size))),
        "lua_close": (None, (state,)),
    }
    for function_name, (return_type, parameters) in signatures.items():
        function = getattr(lua, function_name)
        function.restype = return_type
        function.argtypes = parameters

    vm = lua.luaL_newstate()
    if not vm:
        raise RuntimeError("LuaJIT failed to create a state")
    try:
        lua.luaL_openlibs(vm)
        program = harness.read_bytes()
        status = lua.luaL_loadbuffer(vm, program, len(program), b"@" + harness.name.encode("utf-8"))
        if status == 0:
            lua.lua_pushlstring(vm, body, len(body))
            origin = b"@" + name.encode("utf-8")
            lua.lua_pushlstring(vm, origin, len(origin))
            status = lua.lua_pcall(vm, 2, 0, 0)
        if status != 0:
            length = size()
            error = lua.lua_tolstring(vm, -1, ctypes.byref(length))
            message = "unknown error"
            if error:
                message = ctypes.string_at(error, length.value).decode("utf-8", errors="replace")
            raise RuntimeError(message)
    finally:
        lua.lua_close(vm)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", type=Path, help="ZIP to test (defaults to the build matching VERSION)")
    parser.add_argument("--sdk-dir", type=Path, help="HD2Runtime SDK root containing tools/hd2_archive.py")
    parser.add_argument("--harness", type=Path, default=TEST_DIR / "regression.lua")
    parser.add_argument("--lua-dll", type=Path, default=DEFAULT_DLL)
    arguments = parser.parse_args()
    package = arguments.package
    try:
        if package is None:
            package = default_package()
        body, name = read_addon(package, arguments.sdk_dir)
        run_lua(arguments.lua_dll, arguments.harness, body, name)
    except (OSError, ValueError, KeyError, RuntimeError, struct.error, zipfile.BadZipFile) as error:
        label = package.name if package is not None else "default build"
        print(f"FAIL {label}: {error}", file=sys.stderr)
        return 1
    print(f"PASS {package.name} ({arguments.harness.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
