extends SceneTree

const Session := preload("res://addons/godot_collab/core/session.gd")
const FileSync := preload("res://addons/godot_collab/core/file_sync.gd")
const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")

const PORT := 47934

var _failed := 0
var _checks := 0
var _peers: Array = []
var _root := ""


class FakeEnv:
	extends RefCounted
	var written: Array = []

	func rescan_file(p: String) -> void:
		written.append(p)


class Peer:
	extends RefCounted
	var name := ""
	var session
	var files
	var env
	var dir := ""
	var busy := {}
	var joined_before := false

	func path(rel: String) -> String:
		return dir.path_join(rel)

	func read(rel: String) -> String:
		return FileAccess.get_file_as_string(path(rel)) if FileAccess.file_exists(path(rel)) else "<missing>"

	func write(rel: String, text: String) -> void:
		DirAccess.make_dir_recursive_absolute(path(rel).get_base_dir())
		var f := FileAccess.open(path(rel), FileAccess.WRITE)
		f.store_string(text)
		f.close()

	func make_dir(rel: String) -> void:
		DirAccess.make_dir_recursive_absolute(path(rel))

	func write_bytes(rel: String, bytes: PackedByteArray) -> void:
		DirAccess.make_dir_recursive_absolute(path(rel).get_base_dir())
		var f := FileAccess.open(path(rel), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()

	func hash_of(rel: String) -> String:
		return FileAccess.get_sha256(path(rel)) if FileAccess.file_exists(path(rel)) else ""


func _initialize() -> void:
	Log.console = false
	Log.verbose = false
	call_deferred("_run")


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("FAIL: " + msg)


func _tick() -> void:
	for p in _peers:
		p.session.poll()
		p.files.process()


func _pump(cond: Callable, timeout_s: float = 8.0) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end:
		_tick()
		if cond.call():
			return true
		await create_timer(0.01).timeout
	_tick()
	return cond.call()


func _settle(ms: int = 300) -> void:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		_tick()
		await create_timer(0.01).timeout


func _make_peer(peer_name: String, is_host: bool) -> Peer:
	var p := Peer.new()
	p.name = peer_name
	p.dir = _root.path_join(peer_name.to_lower())
	DirAccess.make_dir_recursive_absolute(p.dir)
	p.session = Session.new()
	p.env = FakeEnv.new()
	p.files = FileSync.new()
	p.files.root_dir = p.dir
	p.files.state_dir = _root.path_join(peer_name.to_lower() + "_state")
	p.files.rescan_pause_ms = 40
	p.files.busy_checker = func(res_path: String) -> bool: return p.busy.has(res_path)
	p.files.setup(p.session, p.env)
	p.session.message.connect(p.files.on_message)
	p.session.joined.connect(func():
		if p.joined_before:
			p.files.session_resumed()
		else:
			p.joined_before = true
			p.files.session_started())
	p.session.link_lost.connect(func(_r): p.files.session_lost())
	_peers.append(p)
	return p


func _connect(p: Peer) -> void:
	p.session.join("127.0.0.1", PORT, "k", p.name)
	await _pump(func(): return p.session.joined_ok)


func _plan_done(p: Peer) -> bool:
	return p.files.scan_complete and not p.files.plan_running


func _remove_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)


func _run() -> void:
	_root = OS.get_temp_dir().path_join("collab_files_test_%d" % Time.get_ticks_msec())
	DirAccess.make_dir_recursive_absolute(_root)
	await _scenario_initial_pull_and_live()
	await _scenario_offline_merge_and_conflict()
	await _scenario_stale_changes_never_win()
	await _scenario_delete_ignore_busy()
	for p in _peers:
		p.files.teardown()
		p.session.shutdown()
	Util.project_dir_override = ""
	Util.state_dir_override = ""
	_remove_dir(_root)
	if _failed > 0:
		printerr("file sync tests failed: %d of %d" % [_failed, _checks])
		quit(1)
	else:
		print("file sync tests passed (%d checks)." % _checks)
		quit()


func _scenario_initial_pull_and_live() -> void:
	var host := _make_peer("Host", true)
	host.write("a.txt", "hello\n")
	host.write("scripts/s.gd", "extends Node\n\nfunc _ready():\n\tpass\n")
	host.write("src/native.cpp", "#include <godot_cpp/core/class_db.hpp>\nint main() { return 0; }\n")
	var blob := PackedByteArray()
	blob.resize(600 * 1024)
	for i in blob.size():
		blob[i] = (i * 31 + 7) % 251
	host.write_bytes("assets/data.bin", blob)
	host.write("assets/data.bin.import", "[remap]\nimporter=\"texture\"\n")
	host.write("scripts/s.gd.uid", "uid://shared-script-id\n")
	host.write(".git/config", "ignored")
	host.write("project.godot", "project settings sync\n")
	host.write("junk.tmp", "ignored")
	host.write(".godot/cache.bin", "ignored cache")
	host.write(".import/legacy-cache.bin", "legacy Godot import cache")
	host.write(".mono/temp/Generated.dll", "generated C# build output")
	host.write("bin/windows.dll", "windows native library")
	host.write("bin/macos.DYLIB", "mac native library")
	host.write("bin/linux.so", "linux native library")
	host.write("locale/en.translation", "imported translation")
	host.write("builds/windows/Game.exe", "windows export")
	host.write("builds/shared/Game.pck", "Godot export pack")
	host.write("builds/android/Game.apk", "Android export")
	host.write("builds/android/Game.aab", "Android app bundle")
	host.write("builds/ios/Game.ipa", "iOS export")
	host.make_dir("builds/ios/Game.xcodeproj/project.xcworkspace")
	host.write("builds/ios/Game.xcodeproj/project.pbxproj", "generated Xcode project")
	host.write("builds/ios/Game.xcodeproj/project.xcworkspace/contents.xcworkspacedata", "generated Xcode workspace")
	host.make_dir("builds/ios/Game.xcworkspace")
	host.write("builds/ios/Game.xcworkspace/contents.xcworkspacedata", "generated Xcode workspace bundle")
	host.make_dir("builds/macos/Game.app/Contents/MacOS")
	host.write("builds/macos/Game.app/Contents/Info.plist", "macOS app bundle")
	host.make_dir("native/Test.framework")
	host.write("native/Test.framework/Info.plist", "macOS framework")
	host.write("addons/godot_collab/private.txt", "ignored collaboration add-on")
	host.write("addons/other_plugin/plugin.gd", "extends EditorPlugin")
	host.session.start_host(PORT, "k", "Host")
	host.files.session_started()
	await _pump(func(): return host.files.scan_complete)
	var cole := _make_peer("Cole", false)
	cole.write("a.txt", "stale local copy\n")
	await _connect(cole)
	var ok: bool = await _pump(func(): return _plan_done(cole) and FileAccess.file_exists(cole.path("assets/data.bin")), 12.0)
	await _settle(200)
	_expect(ok, "a fresh joiner receives the project")
	_expect(cole.hash_of("assets/data.bin") == host.hash_of("assets/data.bin"), "multi-chunk binary file arrives intact")
	_expect(cole.read("scripts/s.gd") == host.read("scripts/s.gd") and cole.read("src/native.cpp") == host.read("src/native.cpp"), "scripts and C++ sources arrive")
	_expect(cole.read("a.txt") == "hello\n", "on first join the host's copy wins over a differing local file")
	var backed_up := false
	var backups := _root.path_join("cole_state").path_join("backups")
	if DirAccess.dir_exists_absolute(backups):
		for stamp in DirAccess.get_directories_at(backups):
			if FileAccess.file_exists(backups.path_join(stamp).path_join("a.txt")):
				backed_up = FileAccess.get_file_as_string(backups.path_join(stamp).path_join("a.txt")) == "stale local copy\n"
	_expect(backed_up, "the replaced local file was backed up")
	_expect(cole.read(".git/config") == "<missing>" and cole.read("project.godot") == "project settings sync\n" and cole.read("junk.tmp") == "<missing>", "project settings sync while metadata and temporary files stay ignored")
	_expect(cole.read(".godot/cache.bin") == "<missing>" and cole.read("addons/godot_collab/private.txt") == "<missing>" and cole.read("addons/other_plugin/plugin.gd") == "<missing>", "editor cache and all add-ons stay out of project sync")
	_expect(cole.read(".import/legacy-cache.bin") == "<missing>" and cole.read(".mono/temp/Generated.dll") == "<missing>", "legacy import and C# generated folders are skipped")
	_expect(cole.read("assets/data.bin.import") == "[remap]\nimporter=\"texture\"\n" and cole.read("scripts/s.gd.uid") == "uid://shared-script-id\n", "Godot import settings and resource UID sidecars stay shared")
	_expect(cole.read("bin/windows.dll") == "<missing>" and cole.read("bin/macos.DYLIB") == "<missing>" and cole.read("bin/linux.so") == "<missing>", "Windows, macOS, and Linux native libraries are skipped case-insensitively")
	_expect(cole.read("locale/en.translation") == "<missing>" and cole.read("builds/windows/Game.exe") == "<missing>" and cole.read("builds/shared/Game.pck") == "<missing>", "generated translations and exported game packages are skipped")
	_expect(cole.read("builds/android/Game.apk") == "<missing>" and cole.read("builds/android/Game.aab") == "<missing>" and cole.read("builds/ios/Game.ipa") == "<missing>", "Android and iOS export packages are skipped")
	_expect(not DirAccess.dir_exists_absolute(cole.path("builds/ios/Game.xcodeproj")) and not DirAccess.dir_exists_absolute(cole.path("builds/ios/Game.xcworkspace")), "iOS Xcode export bundles are skipped as folders")
	_expect(not DirAccess.dir_exists_absolute(cole.path("builds/macos/Game.app")) and not DirAccess.dir_exists_absolute(cole.path("native/Test.framework")), "macOS application and framework bundles are skipped as folders")
	# A file edited outside Godot on the host reaches the client.
	host.write("a.txt", "hello world\n")
	ok = await _pump(func(): return cole.read("a.txt") == "hello world\n")
	_expect(ok, "an external edit on the host is pushed to clients")
	# A client's new file travels through the host to another client.
	var dana := _make_peer("Dana", false)
	await _connect(dana)
	await _pump(func(): return _plan_done(dana) and dana.read("a.txt") == "hello world\n", 12.0)
	cole.write("levels/one.tscn", "[gd_scene format=3]\n")
	ok = await _pump(func(): return host.read("levels/one.tscn") == "[gd_scene format=3]\n" and dana.read("levels/one.tscn") == "[gd_scene format=3]\n")
	_expect(ok, "a file created by a client reaches the host and the others")
	cole.make_dir("plugin_sources/custom_plugin/empty/nested")
	cole.write("plugin_sources/custom_plugin/plugin.cfg", "[plugin]\nname=Custom\n")
	cole.write("plugin_sources/custom_plugin/notes.txt", "plugin notes\n")
	cole.busy["res://scenes/added_in_editor.tscn"] = true
	cole.write("scenes/added_in_editor.tscn", "[gd_scene format=3]\n")
	ok = await _pump(func(): return (
		host.read("plugin_sources/custom_plugin/plugin.cfg") == "[plugin]\nname=Custom\n"
		and dana.read("plugin_sources/custom_plugin/notes.txt") == "plugin notes\n"
		and host.read("scenes/added_in_editor.tscn") == "[gd_scene format=3]\n"
		and DirAccess.dir_exists_absolute(host.path("plugin_sources/custom_plugin/empty/nested"))
		and DirAccess.dir_exists_absolute(dana.path("plugin_sources/custom_plugin/empty/nested"))))
	_expect(ok, "new add-on files, text, a saved scene, and empty nested folders reach every peer")
	cole.busy.clear()
	DirAccess.remove_absolute(cole.path("plugin_sources/custom_plugin/empty/nested"))
	ok = await _pump(func(): return (
		not DirAccess.dir_exists_absolute(host.path("plugin_sources/custom_plugin/empty/nested"))
		and not DirAccess.dir_exists_absolute(dana.path("plugin_sources/custom_plugin/empty/nested"))))
	_expect(ok, "deleting an empty folder propagates to every peer")
	cole.make_dir("heyo/nested")
	cole.write("heyo/nested/keep.txt", "this folder should be deleted everywhere\n")
	ok = await _pump(func(): return (
		host.read("heyo/nested/keep.txt") == "this folder should be deleted everywhere\n"
		and dana.read("heyo/nested/keep.txt") == "this folder should be deleted everywhere\n"))
	_expect(ok, "a populated nested folder is shared before deletion")
	DirAccess.remove_absolute(cole.path("heyo/nested/keep.txt"))
	DirAccess.remove_absolute(cole.path("heyo/nested"))
	DirAccess.remove_absolute(cole.path("heyo"))
	ok = await _pump(func(): return (
		host.read("heyo/nested/keep.txt") == "<missing>"
		and dana.read("heyo/nested/keep.txt") == "<missing>"
		and not DirAccess.dir_exists_absolute(host.path("heyo"))
		and not DirAccess.dir_exists_absolute(dana.path("heyo"))))
	_expect(ok, "deleting a populated folder removes its files and folders everywhere")
	await _settle(200)
	_expect(not DirAccess.dir_exists_absolute(host.path("heyo")) and not DirAccess.dir_exists_absolute(dana.path("heyo")), "a deleted folder does not reappear on the next scan")
	cole.make_dir("heyo/nested")
	cole.write("heyo/nested/reborn.txt", "folder was intentionally recreated\n")
	ok = await _pump(func(): return (
		host.read("heyo/nested/reborn.txt") == "folder was intentionally recreated\n"
		and dana.read("heyo/nested/reborn.txt") == "folder was intentionally recreated\n"))
	_expect(ok, "a folder can be recreated after everyone deleted it")
	var rename_err := DirAccess.rename_absolute(cole.path("heyo"), cole.path("renamed_heyo"))
	ok = await _pump(func(): return (
		rename_err == OK
		and host.read("renamed_heyo/nested/reborn.txt") == "folder was intentionally recreated\n"
		and dana.read("renamed_heyo/nested/reborn.txt") == "folder was intentionally recreated\n"
		and host.read("heyo/nested/reborn.txt") == "<missing>"
		and dana.read("heyo/nested/reborn.txt") == "<missing>"))
	_expect(ok, "renaming a populated folder syncs its new path and removes the old path")
	await _settle(300)
	var written: int = cole.env.written.size()
	await _settle(300)
	_expect(cole.env.written.size() == written, "no echo of synced files")


func _scenario_offline_merge_and_conflict() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	var dana: Peer = _peers[2]
	cole.make_dir("offline_host_delete/empty")
	var dir_ok: bool = await _pump(func(): return (
		DirAccess.dir_exists_absolute(host.path("offline_host_delete/empty"))
		and DirAccess.dir_exists_absolute(dana.path("offline_host_delete/empty"))))
	_expect(dir_ok, "a shared empty folder is present before disconnecting")
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	DirAccess.remove_absolute(host.path("offline_host_delete/empty"))
	DirAccess.remove_absolute(host.path("offline_host_delete"))
	dir_ok = await _pump(func(): return not DirAccess.dir_exists_absolute(dana.path("offline_host_delete")))
	_expect(dir_ok, "host folder deletion reaches connected peers")
	await _connect(cole)
	dir_ok = await _pump(func(): return not DirAccess.dir_exists_absolute(cole.path("offline_host_delete")))
	_expect(dir_ok, "an offline client catches up when the host deleted an empty folder")
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	cole.make_dir("offline_client_add/empty")
	await _settle(150)
	await _connect(cole)
	dir_ok = await _pump(func(): return (
		DirAccess.dir_exists_absolute(host.path("offline_client_add/empty"))
		and DirAccess.dir_exists_absolute(dana.path("offline_client_add/empty"))))
	_expect(dir_ok, "an offline client folder addition reaches the host and other peers on reconnect")
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	DirAccess.remove_absolute(cole.path("offline_client_add/empty"))
	DirAccess.remove_absolute(cole.path("offline_client_add"))
	await _settle(150)
	await _connect(cole)
	dir_ok = await _pump(func(): return (
		not DirAccess.dir_exists_absolute(host.path("offline_client_add"))
		and not DirAccess.dir_exists_absolute(dana.path("offline_client_add"))
		and _plan_done(cole)))
	_expect(dir_ok, "an offline client folder deletion reaches the host and other peers on reconnect")
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	cole.make_dir("offline_client_add/empty")
	await _settle(150)
	await _connect(cole)
	dir_ok = await _pump(func(): return (
		DirAccess.dir_exists_absolute(host.path("offline_client_add/empty"))
		and DirAccess.dir_exists_absolute(dana.path("offline_client_add/empty"))))
	_expect(dir_ok, "an offline folder recreation replaces its old deletion and syncs everywhere")
	var base := "line1\nline2\nline3\nline4\nline5\nline6\n"
	host.write("doc.txt", base)
	await _pump(func(): return cole.read("doc.txt") == base and dana.read("doc.txt") == base)
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	# While Cole is away both sides edit different lines: that merges.
	host.write("doc.txt", "HOST1\nline2\nline3\nline4\nline5\nline6\n")
	cole.write("doc.txt", "line1\nline2\nline3\nline4\nline5\nCOLE6\n")
	cole.write("clash.txt", "a\nb\nc\n")
	host.write("clash.txt", "a\nb\nc\n")
	await _pump(func(): return dana.read("doc.txt").begins_with("HOST1"))
	await _pump(func(): return dana.read("clash.txt") == "a\nb\nc\n")
	await _settle(200)
	await _connect(cole)
	var ok: bool = await _pump(func(): return host.read("doc.txt") == "HOST1\nline2\nline3\nline4\nline5\nCOLE6\n" and cole.read("doc.txt") == host.read("doc.txt"), 12.0)
	_expect(ok, "edits to different lines merge automatically: host=" + host.read("doc.txt").c_escape() + " cole=" + cole.read("doc.txt").c_escape())
	await _pump(func(): return dana.read("doc.txt") == host.read("doc.txt"))
	_expect(dana.read("doc.txt") == host.read("doc.txt"), "and everybody else gets the merged result")
	# Now an overlapping change while apart: held, nothing overwritten.
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	host.write("clash.txt", "a\nHOST-B\nc\n")
	cole.write("clash.txt", "a\nCOLE-B\nc\n")
	await _settle(300)
	await _connect(cole)
	ok = await _pump(func(): return cole.files.conflicts.has("clash.txt"), 12.0)
	_expect(ok, "overlapping edits are held as a conflict")
	_expect(cole.read("clash.txt") == "a\nCOLE-B\nc\n" and host.read("clash.txt") == "a\nHOST-B\nc\n", "neither side was overwritten while held")
	await _settle(600)
	_expect(cole.files.conflicts.has("clash.txt") and cole.read("clash.txt") == "a\nCOLE-B\nc\n", "a held file stays held (not re-sent)")
	# Resolve with markers, then keep-mine / use-theirs on fresh conflicts.
	_expect(cole.files.resolve("clash.txt", "markers"), "markers resolution")
	_expect(cole.read("clash.txt").contains("<<<<<<<") and cole.read("clash.txt").contains("COLE-B") and cole.read("clash.txt").contains("HOST-B"), "markers contain both versions")
	cole.write("clash.txt", "a\nBOTH-B\nc\n")
	ok = await _pump(func(): return host.read("clash.txt") == "a\nBOTH-B\nc\n" and dana.read("clash.txt") == "a\nBOTH-B\nc\n")
	_expect(ok, "the hand-resolved file is shared")
	# Keep mine.
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	host.write("clash.txt", "a\nHOST-C\nc\n")
	cole.write("clash.txt", "a\nCOLE-C\nc\n")
	await _pump(func(): return dana.read("clash.txt") == "a\nHOST-C\nc\n")
	await _connect(cole)
	await _pump(func(): return cole.files.conflicts.has("clash.txt"), 12.0)
	await _settle(300)
	_expect(cole.files.resolve("clash.txt", "mine"), "keep mine")
	ok = await _pump(func(): return host.read("clash.txt") == "a\nCOLE-C\nc\n" and dana.read("clash.txt") == "a\nCOLE-C\nc\n", 10.0)
	_expect(ok, "keep mine overwrites the host's version everywhere")
	# Use theirs.
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	host.write("clash.txt", "a\nHOST-D\nc\n")
	cole.write("clash.txt", "a\nCOLE-D\nc\n")
	await _pump(func(): return dana.read("clash.txt") == "a\nHOST-D\nc\n")
	await _connect(cole)
	await _pump(func(): return cole.files.conflicts.has("clash.txt"), 12.0)
	await _settle(300)
	_expect(cole.files.resolve("clash.txt", "theirs"), "use theirs")
	ok = await _pump(func(): return cole.read("clash.txt") == "a\nHOST-D\nc\n", 10.0)
	_expect(ok and cole.files.conflicts.is_empty(), "use theirs adopts the host's version and clears the conflict")


func _scenario_stale_changes_never_win() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	var dana: Peer = _peers[2]
	# Cole is offline and does NOT touch the file; the host updates it. When Cole returns his old
	# copy must never be sent back over the host's newer one.
	host.write("stale.txt", "v1\n")
	await _pump(func(): return cole.read("stale.txt") == "v1\n" and dana.read("stale.txt") == "v1\n")
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	host.write("stale.txt", "v2 newer\n")
	await _pump(func(): return dana.read("stale.txt") == "v2 newer\n")
	await _connect(cole)
	var ok: bool = await _pump(func(): return cole.read("stale.txt") == "v2 newer\n", 10.0)
	_expect(ok, "an old unchanged copy is brought up to date, not pushed")
	await _settle(500)
	_expect(host.read("stale.txt") == "v2 newer\n" and dana.read("stale.txt") == "v2 newer\n", "the newer version is never overwritten by the old one")
	# A binary file changed on both sides is held, never merged.
	var bin_a := PackedByteArray([1, 2, 3, 4, 5, 6])
	host.write_bytes("pic.png", bin_a)
	await _pump(func(): return cole.hash_of("pic.png") == host.hash_of("pic.png") and dana.hash_of("pic.png") == host.hash_of("pic.png"))
	cole.session.leave()
	await _settle(100)
	cole.files.session_lost()
	host.write_bytes("pic.png", PackedByteArray([9, 9, 9, 9]))
	cole.write_bytes("pic.png", PackedByteArray([7, 7, 7, 7, 7]))
	await _pump(func(): return dana.hash_of("pic.png") == host.hash_of("pic.png"))
	await _connect(cole)
	ok = await _pump(func(): return cole.files.conflicts.has("pic.png"), 12.0)
	_expect(ok, "a binary file changed on both sides is held")
	_expect(FileAccess.get_file_as_bytes(cole.path("pic.png")).size() == 5 and FileAccess.get_file_as_bytes(host.path("pic.png")).size() == 4, "both binary versions untouched")
	cole.files.resolve("pic.png", "theirs")
	ok = await _pump(func(): return cole.hash_of("pic.png") == host.hash_of("pic.png"), 8.0)
	_expect(ok, "use theirs on a binary file")


func _scenario_delete_ignore_busy() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	var dana: Peer = _peers[2]
	cole.write("trash.txt", "bye\n")
	await _pump(func(): return host.read("trash.txt") == "bye\n" and dana.read("trash.txt") == "bye\n")
	DirAccess.remove_absolute(cole.path("trash.txt"))
	var ok: bool = await _pump(func(): return host.read("trash.txt") == "<missing>" and dana.read("trash.txt") == "<missing>", 10.0)
	_expect(ok, "a deletion propagates to everybody (host=%s dana=%s)" % [host.read("trash.txt"), dana.read("trash.txt")])
	var stale := "stale pre-delete transfer\n".to_utf8_buffer()
	var stale_hash := Util.sha256_bytes(stale)
	dana.files.on_message({"t": "file_data", "rel": "trash.txt", "hash": stale_hash, "count": 1})
	dana.files.on_message({"t": "file_chunk", "rel": "trash.txt", "hash": stale_hash, "i": 0, "data": stale})
	_expect(dana.read("trash.txt") == "<missing>", "a stale in-flight pull cannot resurrect a deleted file")
	var backed := false
	var backups := _root.path_join("host_state").path_join("backups")
	if DirAccess.dir_exists_absolute(backups):
		for stamp in DirAccess.get_directories_at(backups):
			if FileAccess.file_exists(backups.path_join(stamp).path_join("trash.txt")):
				backed = true
	_expect(backed, "the deleted file is kept in the host's backups")
	# Busy (open in an editor) files are left alone until they close.
	host.write("open.gd", "v1\n")
	await _pump(func(): return cole.read("open.gd") == "v1\n")
	cole.busy["res://open.gd"] = true
	host.write("open.gd", "v2 from host\n")
	await _settle(800)
	_expect(cole.read("open.gd") == "v1\n", "a file open in a live editor is not overwritten behind its back")
	cole.busy.clear()
	ok = await _pump(func(): return cole.read("open.gd") == "v2 from host\n", 12.0)
	_expect(ok, "it catches up once the editor closes it")
