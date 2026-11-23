# Godot Collab (Prototype)

A source-only Godot editor add-on prototype for testing LAN scene and project-file collaboration. It is intentionally separate from the existing collaboration add-ons in this project.

Open scripts show collaborators' live caret positions and text selections. The 2D and 3D scene viewports also show the nodes each collaborator has selected. These indicators use each collaborator's assigned session color and do not change the local editor selection.

Each editor can set its displayed name and highlight color. The Session tab can search teammates, jump to a teammate's active script cursor or 3D editor camera, and copy LAN invite details for the host to send to a friend. Closing or disconnecting an editor sends a clean leave notice so peers remove it promptly.

Tested with Godot 4.7.2; the add-on targets Godot 4.7 and newer. It is written in GDScript with no native binaries, so Windows and macOS editors can connect when they use matching protocol, Godot major/minor, and configured project versions. The current automated run was performed on Windows; a native macOS run is still required.

## Install in this project

The add-on is already in `res://addons/godot_collab`. In Godot, open **Project > Project Settings > Plugins** and enable **Godot Collab (Prototype)**. Open the **Godot Collab** dock on the right.

To try it in another project, copy the entire `godot_collab` folder into that project's `res://addons/` directory, then enable `plugin.cfg` in Project Settings > Plugins. The add-on uses GDScript and has no native binary or external package dependency. A tagged ZIP and Godot Asset Library listing can be added after the prototype is tested.

Enter the same project code in each separate project copy. It is saved locally per copy; set a custom code before making offline edits, because changing codes selects a different recovery journal. For version mismatch checks, set **Project > Project Settings > Application > Config > Version** to the same project version in every copy. If that field is blank, the add-on cannot detect different project revisions by version name alone.

## LAN test

1. Use separate copies of the game folder. Do not open the same physical project folder in two editors. Use the same Godot major/minor version, project code, and configured project version.
2. In the first editor, enter a project code and choose **Host on this computer**.
3. Join from another device using the host computer's LAN IP and the same project code. `127.0.0.1` only works for editors on the same computer. On macOS, `ipconfig getifaddr en0` usually prints the Wi-Fi address; on Windows, use `ipconfig`.
4. Allow the Godot editor through each computer's firewall. On macOS, accept any local-network permission prompt; guest Wi-Fi or client isolation may block device-to-device connections.
5. Move or rotate a `Node2D` or `Node3D`; supported transforms and visibility are polled and sent while connected.
6. Save a file or asset in Godot or an external editor. Saved project files and folders outside `addons/` sync by their project-relative path, including scripts, scenes, text files, and binary assets. New files, renames, deletions, and empty folders propagate too. Godot's `.godot`, legacy `.import`, and `.mono` generated folders, generated translations, exported game packages, platform-specific native libraries/build outputs, and the entire `addons/` folder are excluded.
7. To test reconnects, make an edit while disconnected, reconnect, and check that it catches up. If the same file or scene property changed independently, both versions are preserved and the dock offers **Keep mine** or **Use theirs**.

When running two Godot editors on one computer, messages that ports 6005 or 6006 are already in use refer to Godot's optional language-server/debugger services, not this add-on's collaboration connection. Give those editor services different ports in each instance's Editor Settings (search for `6005` or `6006`), or disable the unused service in one instance.

The host editor must be running for a client to join and catch up. A client retries a dropped connection with backoff, remembers its last host, and reconnects/catches up on the next editor launch. **Disconnect** clears the remembered host. The host stores its operation history, and each client stores its pending outbox, baseline, unresolved conflicts, project code, host address, and last received revision, under Godot's local `user://godot_collab/` data directory. This keeps collaboration state out of the game files and Git; closing Godot does not discard queued edits.

## Source-file behavior

The add-on watches the project on disk, so saved files and folders from Godot or an external editor are transferred while the editor is running. It handles files of any extension, including scenes, scripts, text documents, and binary assets, up to the configured file-size limit (128 MiB by default), except generated caches/build products and anything under `addons/`. The `.godot`, legacy `.import`, and `.mono` generated folders, generated `.translation` files, exported `.exe`/`.pck`/`.app`/`.apk`/`.aab`/`.ipa` packages and Xcode bundles, platform-specific native libraries (`.dll`, `.dylib`, `.so`, framework bundles), compiler outputs, the entire `addons/` folder, version-control metadata, temporary files, and paths listed in `.collabignore` are excluded. Godot `.import` settings and `.uid` sidecars outside `addons/` are intentionally synced with their source assets; Godot regenerates the imported cache locally. `project.godot` is included. Offline edits are reconciled on reconnect or the next editor launch.

Rapid saves to one file are debounced. A saved local file is sent even while it is open; an incoming disk write waits while that file is open, and the live script/scene sync handles in-editor edits. Non-overlapping edits to supported text files can merge; conflicting edits and binary-file conflicts are held for a **Keep mine** or **Use theirs** choice, with backups made before replacement. Remote files are written to disk and trigger a Godot filesystem scan; an already-open script tab may need to be reloaded. The add-on syncs saved `.cpp`/`.h` text, but does not build native extensions.

The transport refuses clients with a different collaboration protocol, Godot major/minor version, or configured project version. Matching version strings do not prove that two project copies contain identical files; divergent file bases are detected as conflicts rather than overwritten.

## Safety and current limits

This prototype uses an unencrypted TCP connection and does not provide accounts, invitation approval, or a secure authentication protocol. Source-file sync can write peer-provided text into the project. Use it only on a trusted LAN with trusted collaborators. Do not port-forward it or expose it to the internet. The project code is a routing check, not a password.

For open saved scenes, node creation, deletion, renaming, reparenting, sibling ordering, supported properties, groups, and persistent connections sync live. Scene edits arrive in the editor and are marked unsaved; save the scene in Godot to persist them to its `.tscn` file. Both editors need the same scene path. Unsaved scenes without a `res://` path are not tracked. Offline scene edits are reconciled when the connection returns. The project watcher separately transfers saved files, binary assets, folder creation/deletion, additions, deletions, and renames.

The terrain merge core treats sculpting as additive per-cell height deltas, so edits to different cells merge and overlapping raise/lower strokes add deterministically. Competing writes to the same material/value cell and base revision are kept as a conflict. This merge core is tested independently, but it is **not yet wired to this project's terrain generator**: `TerrainGen.gd` currently generates terrain from noise and has no persistent sculpt/paint edit interface. Do not treat terrain sculpt edits as synchronized until that adapter is implemented.

## Tests

With Godot 4.7.2 installed, run these from the project root. On Windows, use the console executable:

```powershell
$godot = 'C:\Path\To\Godot_v4.7.2-stable_win64_console.exe'
$tests = @(
  'diff3_test.gd',
  'file_sync_test.gd',
  'model_test.gd',
  'ot_test.gd',
  'scene_sync_test.gd',
  'script_sync_test.gd',
  'session_test.gd',
  'terrain_merge_test.gd'
)
foreach ($test in $tests) {
  & $godot --headless --path . --script "res://addons/godot_collab/tests/$test"
  if ($LASTEXITCODE -ne 0) { throw "Godot test failed: $test" }
}
```

The real two-editor integration test is `addons/godot_collab/tests/editor/run_e2e.ps1` on Windows. On macOS, run the same two-editor test with `GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot bash addons/godot_collab/tests/editor/run_e2e.sh` (or use `GODOT_BIN=godot` if it is on your PATH). Run each unit test with `godot --headless --path . --script res://addons/godot_collab/tests/<test>.gd`. The add-on and test harness use Godot's cross-platform GDScript, TCP, and path APIs; a native Mac run is still needed to confirm macOS firewall prompts and device-to-device networking.
