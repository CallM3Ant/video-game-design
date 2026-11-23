# NewestGodot

## Native terrain

Terrain generation uses a Godot C++ GDExtension. On Windows x64, teammates
who only edit scripts can use the project with a matching debug DLL in `bin/`;
they only need the C++ toolchain if they rebuild the extension. The current
extension configuration registers Windows x64 debug and release libraries.
A Web extension has not been built or configured yet.

To rebuild on Windows, initialize the `godot-cpp` submodule, install Python,
SCons (`py -m pip install scons`), and the Visual Studio C++ Build Tools with
the Windows SDK. From an x64 Native Tools Command Prompt, in the project root:

```bat
git submodule update --init --recursive
py -m SCons platform=windows target=template_debug arch=x86_64
py -m SCons platform=windows target=template_release arch=x86_64
```

The release DLL is needed for Windows release exports. Restart Godot after
rebuilding so it loads the new DLLs.

## Terrain settings and checks

- **Terrain LOD** is off by default and saved when graphics settings are
  applied. It reduces distant rendered triangles while retaining full chunk
  borders and the existing collision detail. It adds index buffers and does
  not reduce the base vertex-buffer size.
- The mesh-cache budget limits cached array data in MiB, not live meshes or
  bookkeeping; zero means unlimited. When full, pre-generation favors nearer
  chunks over farther cached entries.
- Run `Godot --headless --path . --script res://scripts/Terrain/TerrainNativeParityCheck.gd`
  to check native terrain, cache behavior, LOD topology and settings.
- Run `Godot --headless --path . --script res://scripts/Terrain/TerrainProfiler.gd -- --quick --skip-area`
  for a short performance and streaming profile. Its timings are not gameplay FPS.

Replace `Godot` with the path to your Godot console executable.
