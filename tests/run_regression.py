"""Run a packaged addon in an isolated LuaJIT state with an offline harness."""

from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import struct
import sys
import zipfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
ARCHIVE_TOOL = TEST_DIR.parents[1] / ".tools" / "sdk" / "tools" / "hd2_archive.py"
DEFAULT_DLL = Path(r"E:\Hellforge\HellForge\game\bin\lua51.dll")


def read_addon(package: Path) -> tuple[bytes, str]:
    spec = importlib.util.spec_from_file_location("hd2_archive", ARCHIVE_TOOL)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load SDK archive reader at {ARCHIVE_TOOL}")
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
    parser.add_argument("package", type=Path, help="FieldSampleDrops ZIP to test")
    parser.add_argument("--harness", type=Path, default=TEST_DIR / "regression.lua")
    parser.add_argument("--lua-dll", type=Path, default=DEFAULT_DLL)
    arguments = parser.parse_args()
    try:
        body, name = read_addon(arguments.package)
        run_lua(arguments.lua_dll, arguments.harness, body, name)
    except (OSError, ValueError, KeyError, RuntimeError, struct.error, zipfile.BadZipFile) as error:
        print(f"FAIL {arguments.package.name}: {error}", file=sys.stderr)
        return 1
    print(f"PASS {arguments.package.name} ({arguments.harness.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
