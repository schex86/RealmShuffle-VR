extends RefCounted

const Adaptive = preload("res://scripts/realm_adaptive_shuffle.gd")
const VIDEO_DIR = "/sdcard/Movies/RealmShuffle/Videos"

var engine := Adaptive.new()
var active := false
var _host_ref: WeakRef
var _startup_delay := 0.0
var _startup_attempts := 0
var _opening := false
var _opening_time := 0.0
var _expected_uri := ""
var _duration_known := false

func _init(host: Node3D) -> void:
    _host_ref = weakref(host)
    print("[RealmShuffle 0.7.3] Controller initialized")

func activate() -> bool:
    var host := _host_ref.get_ref() as Node3D
    if not is_instance_valid(host) or not host.video:
        return false

    var directory := DirAccess.open(VIDEO_DIR)
    if directory == null:
        print("[RealmShuffle] Library unavailable: ", DirAccess.get_open_error())
        return false

    var entries: Array[Dictionary] = []
    var uris: Array[String] = []

    for filename in directory.get_files():
        if filename.get_extension().to_lower() != "mp4":
            continue
        var uri: String = "file://" + VIDEO_DIR.path_join(filename)
        entries.append({
            "uri": uri,
            "title": filename.get_basename(),
            "metadata": {"basename": filename}
        })
        uris.append(uri)

    if entries.is_empty():
        print("[RealmShuffle] No videos discovered")
        return false

    host.playback_queue.replace(entries)
    host.playback_queue.custom = true
    engine.configure(uris)
    engine.automatic = true
    active = true

    print("[RealmShuffle] Discovered ", entries.size(), " videos")
    next_scene()
    return true

func deactivate() -> void:
    active = false
    _opening = false

func _dismiss_menus(host: Node3D) -> void:
    if host.library_menu and host.library_menu.visible:
        host.library_menu.hide()
    if host.player_menu and host.player_menu.visible:
        host.player_menu.dismiss()

func _open(uri: String) -> void:
    var host := _host_ref.get_ref() as Node3D
    if not is_instance_valid(host) or uri.is_empty():
        return

    var item: Dictionary = host.playback_queue.find(uri)
    if item.is_empty():
        print("[RealmShuffle] Queue item missing: ", uri)
        return

    _capture_session_zoom(host)

    _opening = true
    _opening_time = 0.0
    _duration_known = false
    _expected_uri = uri
    _quiet_loop_pending = false
    _quiet_loop_wait = 0.0
    _sync_loop_count = 0
    _sync_last_position = -1.0
    _sync_loaded_uri = ""
    _sync_force_seek = true
    _sync_last_paused = false

    host.video.loop_enabled = true
    _video_only_paused = false
    host.video.requested_play = true

    print("[RealmShuffle] Opening: ", item.title)

    if host.video.layer_controller:
        host.video.layer_controller.surface_allowed = false

        print(
            "[RealmShuffle FrameHold] Texture rendering selected"
        )

    var opened: bool = host.video.open_library(
        str(item.uri),
        str(item.title),
        item.get("metadata", {}),
        true
    )

    if opened:
        _restore_session_zoom(host)
        _dismiss_menus(host)
    else:
        _opening = false
        print("[RealmShuffle] Open rejected: ", uri)

func next_scene(reason: String = "automatic") -> void:
    if active and not _opening and not transition_active:
        var destination: String = engine.next_scene()
        _usage_video_navigation(destination, reason)
        _transition_to(destination)

func previous_scene() -> void:
    if active and not _opening and not transition_active:
        var destination: String = engine.previous_scene()
        _usage_video_navigation(destination, "previous")
        _transition_to(destination)

func toggle_automatic() -> void:
    if not active:
        activate()
        return
    engine.automatic = not engine.automatic
    _usage_write("video", "automatic_changed", {
        "enabled": engine.automatic,
        "media_id": _usage_video_id,
        "active_seconds": _usage_video_seconds
    })
    print("[RealmShuffle] Automatic advancement: ", engine.automatic)

func tick(delta: float) -> void:
    var host := _host_ref.get_ref() as Node3D
    if not is_instance_valid(host) or not host.video:
        return

    _usage_tick(host, delta)
    _performance_tick(host, delta)
    _frame_hold_diagnostics(host)
    _music_tick(host, delta)
    _beat_tick(host)
    _controller_labels_tick(host, delta)

    _fade_tick(host, delta)

    if not host.wearer_present:
        return

    if not active:
        _startup_delay += delta
        if _startup_delay >= 3.0 and _startup_attempts < 10:
            _startup_delay = 0.0
            _startup_attempts += 1
            print("[RealmShuffle] Startup attempt ", _startup_attempts)
            activate()
        return

    var video = host.video

    if _opening:
        _opening_time += delta
        if _opening_time > 30.0:
            _opening = false
            print("[RealmShuffle] Video opening timeout")
            return

    if video.media.state != "playing":
        return

    if not video.requested_play:
        return

    if video.local_uri != _expected_uri:
        return

    _enforce_vr180(video)

    if not _duration_known:
        _restore_session_zoom(host)
        var duration: float = float(video.control.duration_ms) / 1000.0
        if duration <= 0.0:
            return

        engine.begin_scene(duration)
        _duration_known = true
        _opening = false

        print(
            "[RealmShuffle] Playing: ", video.display_name,
            " | Natural seconds: ", duration,
            " | Target seconds: ", engine.target_duration(duration)
        )

    video.loop_enabled = (
        engine.requires_loop(engine.original_duration)
        or not engine.automatic
    )

    if engine.requires_loop(engine.original_duration):
        if engine.tick(delta, true):
            print("[RealmShuffle] Adaptive duration reached")
            next_scene("adaptive_complete")

    _quiet_end_tick(host, delta)

func handle_ended() -> void:
    if active and engine.automatic and not _opening:
        print("[RealmShuffle] Natural video ending")
        next_scene("natural_complete")

func handle_button(action: String, hand: String) -> bool:
    var host := _host_ref.get_ref() as Node3D

    if not is_instance_valid(host) or not host.video:
        return false

    if action == "grip_click" and hand == "left_hand" and active:
        _toggle_performance_overlay(host)
        return true

    if action == "trigger_click" and hand == "left_hand":
        if active and host.input_source.active_menu() == null:
            sync_current_scene()
            return true
        return false

    if action not in ["ax_button", "by_button"]:
        return false

    print("[RealmShuffle] Button: ", hand, " / ", action)

    if not active:
        activate()
        return true

    match action:
        "ax_button":
            if hand == "right_hand":
                next_scene("manual_next")
            elif hand == "left_hand":
                _toggle_video_only(host)
            return true
        "by_button":
            if hand == "right_hand":
                previous_scene()
            elif hand == "left_hand":
                toggle_automatic()
            return true

    return false

# REALMSHUFFLE_AUDIO_ENGINE

const MUSIC_DIR = "/sdcard/Movies/RealmShuffle/Music"

var _music_player: AudioStreamPlayer
var _music_files: Array[String] = []
var _music_index := -1
var _music_scan_delay := 0.0
var _music_volume := 0.35

func _music_initialize(host: Node3D) -> void:
    if is_instance_valid(_music_player):
        return

    _music_player = AudioStreamPlayer.new()
    _music_player.name = "RealmShuffleMusic"
    _music_player.volume_db = linear_to_db(_music_volume)
    host.add_child(_music_player)

    _music_player.finished.connect(_on_music_finished)

    print("[RealmShuffle Audio] Player initialized")

    _music_scan()

func _music_scan() -> void:
    var directory := DirAccess.open(MUSIC_DIR)

    if directory == null:
        print("[RealmShuffle Audio] Directory unavailable")
        return

    _music_files.clear()

    for filename in directory.get_files():
        if filename.get_extension().to_lower() in ["mp3", "ogg", "wav"]:
            _music_files.append(MUSIC_DIR.path_join(filename))

    _music_files.shuffle()
    _music_index = -1

    print("[RealmShuffle Audio] Discovered ", _music_files.size(), " tracks")

    if not _music_files.is_empty():
        _music_next()

func _music_next() -> void:
    if not is_instance_valid(_music_player):
        return

    if _music_files.is_empty():
        return

    for attempt in range(_music_files.size()):
        _music_index += 1

        if _music_index >= _music_files.size():
            _music_files.shuffle()
            if _music_files.size() > 1 and _music_files[0] == _current_music_path:
                var first: String = _music_files.pop_front()
                _music_files.append(first)
            _music_index = 0

        var path: String = _music_files[_music_index]
        var stream: AudioStream = null

        match path.get_extension().to_lower():
            "mp3":
                stream = AudioStreamMP3.load_from_file(path)
            "ogg":
                stream = AudioStreamOggVorbis.load_from_file(path)
            "wav":
                stream = AudioStreamWAV.load_from_file(path)

        if stream == null:
            print("[RealmShuffle Audio] Cannot load ", path)
            continue

        if stream is AudioStreamMP3:
            stream.loop = false
        elif stream is AudioStreamOggVorbis:
            stream.loop = false
        elif stream is AudioStreamWAV:
            stream.loop_mode = AudioStreamWAV.LOOP_DISABLED

        _current_music_path = path
        _music_player.stream = stream
        _music_player.play()

        print("[RealmShuffle Audio] Playing ", path.get_file())
        return

func _music_tick(host: Node3D, delta: float) -> void:
    if not active:
        return

    if not is_instance_valid(_music_player):
        _music_initialize(host)

    if not is_instance_valid(_music_player):
        return

    _music_player.stream_paused = (
        not host.wearer_present
        or (
            not host.video.requested_play
            and not _video_only_paused
        )
    )

    _scene_sync_tick(host, delta)

    if _music_files.is_empty():
        _music_scan_delay += delta

        if _music_scan_delay >= 15.0:
            _music_scan_delay = 0.0
            _music_scan()

# REALMSHUFFLE_TRANSITION_ENGINE

const FADE_OUT_SECONDS := 0.8
const FADE_IN_SECONDS := 1.2

var transition_active := false
var _fade_phase := 0
var _fade_amount := 0.0
var _fade_target_uri := ""
var _fade_wait := 0.0

var _fade_mesh: MeshInstance3D
var _fade_material: StandardMaterial3D

func _fade_initialize(host: Node3D) -> void:
    if is_instance_valid(_fade_mesh):
        return

    if not is_instance_valid(host.xr_camera):
        return

    _fade_material = StandardMaterial3D.new()
    _fade_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _fade_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    _fade_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    _fade_material.no_depth_test = true
    _fade_material.render_priority = 127
    _fade_material.albedo_color = Color(0, 0, 0, 0)

    var sphere := SphereMesh.new()
    sphere.radius = 0.3
    sphere.height = 0.6
    sphere.radial_segments = 32
    sphere.rings = 16

    _fade_mesh = MeshInstance3D.new()
    _fade_mesh.name = "RealmShuffleFade"
    _fade_mesh.mesh = sphere
    _fade_mesh.material_override = _fade_material
    _fade_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

    host.xr_camera.add_child(_fade_mesh)
    _fade_mesh.visible = false

    print("[RealmShuffle Fade] Initialized")

func _fade_set(value: float) -> void:
    _fade_amount = clampf(value, 0.0, 1.0)

    if is_instance_valid(_fade_mesh):
        _fade_mesh.visible = _fade_amount > 0.001
        _fade_material.albedo_color = Color(
            _selected_fade_color.r,
            _selected_fade_color.g,
            _selected_fade_color.b,
            smoothstep(0.0, 1.0, _fade_amount)
        )

func _transition_to(uri: String) -> void:
    if uri.is_empty() or transition_active:
        return

    var host := _host_ref.get_ref() as Node3D

    if not is_instance_valid(host):
        return

    _select_peaceful_transition(
        host.video.local_uri.is_empty()
    )
    _fade_initialize(host)

    if not is_instance_valid(_fade_mesh):
        _open(uri)
        return

    transition_active = true
    _fade_target_uri = uri
    _fade_wait = 0.0

    _dismiss_menus(host)

    if host.video.local_uri.is_empty():
        _fade_set(1.0)
        _fade_phase = 2
        _open(uri)
    else:
        _fade_set(0.0)
        _fade_phase = 1

    print("[RealmShuffle Fade] Transition started")

func _fade_tick(host: Node3D, delta: float) -> void:
    if not transition_active:
        return

    match _fade_phase:
        1:
            _fade_set(_fade_amount + delta / _selected_fade_out)

            if _fade_amount >= 1.0:
                _fade_phase = 2
                _fade_wait = 0.0
                _open(_fade_target_uri)

        2:
            _fade_wait += delta

            if (
                _duration_known
                and not _opening
                and host.video.local_uri == _fade_target_uri
                
                and host.video.media.state == "playing"
                and not host.video.waiting_for_first_frame()
            ):
                _restore_session_zoom(host)
                _fade_phase = 3
                print("[RealmShuffle Fade] New video ready")

            elif _fade_wait >= 3.0:
                _opening = false
                _restore_session_zoom(host)
                _fade_phase = 3
                print("[RealmShuffle Fade] Loading timeout")

        3:
            _fade_set(_fade_amount - delta / _selected_fade_in)

            if _fade_amount <= 0.0:
                _fade_phase = 0
                transition_active = false
                print("[RealmShuffle Fade] Transition complete")

# REALMSHUFFLE_CONTROLLER_LABELS

var _controller_labels: Dictionary = {}
var _label_retry := 0.0

func _make_controller_label(
    parent: Node3D,
    label_name: String,
    message: String,
    offset: Vector3,
    tint: Color
) -> Label3D:

    var label := Label3D.new()
    label.name = label_name
    label.text = message
    label.position = offset
    label.font_size = 28
    label.pixel_size = 0.00045
    label.outline_size = 10
    label.modulate = Color.WHITE
    label.outline_modulate = Color(0.015, 0.02, 0.035, 1.0)
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    label.render_priority = 10
    label.shaded = false
    parent.add_child(label)
    return label

func _find_controller_grip(
    host: Node3D,
    side: String
) -> Node3D:

    var gate := host.find_child(
        side.capitalize() + "Controller",
        true,
        false
    ) as Node3D

    if not is_instance_valid(gate):
        return null

    for child in gate.get_children():
        if child is XRNode3D:
            return child as Node3D

    return null

func _install_controller_labels(host: Node3D) -> void:

    for side in ["left", "right"]:

        if _controller_labels.has(side):
            continue

        var grip := _find_controller_grip(host, side)

        if not is_instance_valid(grip):
            continue

        var offset := Vector3(-0.115 if side == "left" else 0.115, 0.135, -0.025)

        var tint := (
            Color(0.75, 1.0, 0.95, 1.0)
            if side == "left"
            else Color(0.91, 0.86, 1.0, 1.0)
        )

        var label := _make_controller_label(
            grip,
            "RealmShuffleButtonGuide",
            "",
            offset,
            tint
        )

        _controller_labels[side] = label

        print(
            "[RealmShuffle Labels] Installed ",
            side,
            " controller guide"
        )

func _controller_labels_tick(
    host: Node3D,
    delta: float
) -> void:

    if _controller_labels.size() < 2:

        _label_retry += delta

        if _label_retry >= 1.0:
            _label_retry = 0.0
            _install_controller_labels(host)

    for side in _controller_labels:

        var label: Label3D = _controller_labels[side]

        if not is_instance_valid(label):
            continue

        label.visible = (
            active
            and host.wearer_present
            and not transition_active
        )

        var message := ""

        if side == "left":
            var action := (
                "Pause Video Only"
                if host.video.requested_play
                else "Play Video Only"
            )

            var automatic := (
                "ON" if engine.automatic else "OFF"
            )

            message = (
                "X  " + action
                + "\nY  Auto: " + automatic
                + "\nStick L/R: Beat"
                + "\n" + _beat_descriptor()
                + "\nStick U/D: Volume"
                + "\nBeat Volume: " + _beat_volume_status()
                + "\nStick Click: Random Music"
                + "\n" + _music_display_title()
                + "\nTrigger: " + _sync_status_text()
                + "\nGrip: Performance"
            )
        else:

            message = (
                "A  Next Scene"
                + "\nB  Previous Scene"
                + "\n" + _scene_controller_status(host)
                + "\nStick L/R: Seek"
                + "\nStick U/D: Zoom"
                + "\nStick Click: Center"
                + "\nTrigger: Menu"
                + "\nGrip: Adjust View"
            )

        _render_colored_guide(label, message, str(side))

# REALMSHUFFLE_BINAURAL_ENGINE

const BEAT_FREQUENCIES: Array[float] = [
    0.0, 1.0, 2.0, 4.0, 8.0,
    12.0, 24.0, 32.0, 40.0
]

const BEAT_CARRIER := 220.0
const BEAT_SAMPLE_RATE := 24000.0

var _beat_index := 0
var _beat_volume := 0.10
var _beat_latched := false

var _beat_player: AudioStreamPlayer
var _beat_playback: AudioStreamGeneratorPlayback

var _beat_phase_left := 0.0
var _beat_phase_right := 0.0
var _beat_gain := 0.0
var _beat_current_hz := 0.0

func _beat_status() -> String:
    if _beat_index == 0:
        return "OFF"
    return "%d Hz" % int(BEAT_FREQUENCIES[_beat_index])

func _beat_volume_status() -> String:
    return "%d%%" % int(round(_beat_volume * 100.0))

func _beat_initialize(host: Node3D) -> void:
    if is_instance_valid(_beat_player):
        return

    var stream := AudioStreamGenerator.new()
    stream.mix_rate = BEAT_SAMPLE_RATE
    stream.buffer_length = 0.15

    _beat_player = AudioStreamPlayer.new()
    _beat_player.name = "RealmShuffleBinaural"
    _beat_player.stream = stream
    host.add_child(_beat_player)
    _beat_player.play()

    _beat_playback = (
        _beat_player.get_stream_playback()
        as AudioStreamGeneratorPlayback
    )

    print("[RealmShuffle Beats] Generator initialized")

func _beat_tick(host: Node3D) -> void:
    if not active:
        return

    if not is_instance_valid(_beat_player):
        if _beat_index == 0:
            return
        _beat_initialize(host)

    if not is_instance_valid(_beat_playback):
        return

    var target_gain := 0.0

    if (
        _beat_index != 0
        and host.wearer_present
        and (
            host.video.requested_play
            or transition_active
            or _video_only_paused
        )
    ):
        target_gain = _beat_volume * 0.12

    var target_hz: float = BEAT_FREQUENCIES[_beat_index]
    var available: int = _beat_playback.get_frames_available()

    if available <= 0:
        return

    var frames := PackedVector2Array()
    frames.resize(available)

    for i in range(available):

        # Smooth amplitude and frequency changes.
        _beat_gain = move_toward(
            _beat_gain, target_gain, 0.000015
        )

        _beat_current_hz = move_toward(
            _beat_current_hz, target_hz, 0.005
        )

        var left_hz := BEAT_CARRIER - _beat_current_hz * 0.5
        var right_hz := BEAT_CARRIER + _beat_current_hz * 0.5

        _beat_phase_left = fposmod(
            _beat_phase_left + TAU * left_hz / BEAT_SAMPLE_RATE,
            TAU
        )

        _beat_phase_right = fposmod(
            _beat_phase_right + TAU * right_hz / BEAT_SAMPLE_RATE,
            TAU
        )

        frames[i] = Vector2(
            sin(_beat_phase_left) * _beat_gain,
            sin(_beat_phase_right) * _beat_gain
        )

    _beat_playback.push_buffer(frames)

func handle_binaural_stick(stick: Vector2) -> bool:
    var host := _host_ref.get_ref() as Node3D

    if not is_instance_valid(host) or not active:
        return false

    if not host.input_source.input_focused():
        _beat_latched = true
        return false

    if host.input_source.active_menu() != null:
        _beat_latched = true
        return false

    if stick.length() < 0.30:
        _beat_latched = false
        return true

    if host.input_visuals:
        host.input_visuals.controller_activity("left_hand")

    if _beat_latched or transition_active:
        return true

    if absf(stick.x) > 0.75 and absf(stick.y) < 0.35:

        var direction := 1 if stick.x > 0.0 else -1

        _beat_index = posmod(
            _beat_index + direction,
            BEAT_FREQUENCIES.size()
        )

        _beat_latched = true

    elif absf(stick.y) > 0.75 and absf(stick.x) < 0.35:

        var direction := 1.0 if stick.y > 0.0 else -1.0

        _beat_volume = clampf(
            _beat_volume + direction * 0.05,
            0.0,
            1.0
        )

        _beat_latched = true

    if _beat_latched:
        print(
            "[RealmShuffle Beats] ",
            _beat_status(),
            " | Volume ",
            _beat_volume_status(),
            " | Carrier ",
            BEAT_CARRIER,
            " Hz"
        )

    return true

# REALMSHUFFLE_BEAT_DESCRIPTORS

const BEAT_DESCRIPTORS: Array[String] = [
    "OFF | Music Only",
    "1 Hz | Delta | Deep Sleep",
    "2 Hz | Delta | Sleep",
    "4 Hz | Theta | Deep Relaxation",
    "8 Hz | Alpha | Calm Focus",
    "12 Hz | Alpha | Relaxed Alertness",
    "24 Hz | Beta | Concentration",
    "32 Hz | Gamma | Mental Clarity",
    "40 Hz | Gamma | Cognitive Focus"
]

func _beat_descriptor() -> String:
    return BEAT_DESCRIPTORS[_beat_index]

# REALMSHUFFLE_OFFICIAL_SCENE_REGISTRY

const SCENE_TITLES: Dictionary = {
    "ASM": "Altered States of Mycelia",
    "ATL": "Atmospheric Longing",
    "BOQ": "Bliss of the Quest",
    "CAP": "Capacity",
    "CAS": "Calm Amidst the Storm",
    "CUR": "Curiosity",
    "DIS": "Dissolve",
    "EON": "Edge of Now",
    "EVA": "Evanescence",
    "FLD": "Flowing Depths",
    "FLW": "Vivid Flow",
    "GOA": "Glimpses of Anatta",
    "HOW": "Home Within",
    "HYP": "Hypnotic Flow",
    "LOL": "Light of Life",
    "MAV": "Magical Vastness",
    "MEL": "Mellow Embrace",
    "NAC": "Nature's Calling",
    "OSW": "Oceanic Sway",
    "POL": "Pulse of Life",
    "REF": "Reflect",
    "TLB": "Timeless Being",
    "TTC": "To the Core",
    "WSS": "Starry Blankets",
    "DISSOLVE": "Dissolve"
}

func _official_scene_title(uri: String) -> String:
    if uri.is_empty():
        return "No Scene Selected"

    var filename := uri.get_file().uri_decode().get_basename()

    var clean := filename

    for suffix in [
        "_180_LR", "_180_TB",
        "_360_LR", "_360_TB",
        "_8K", "_7K", "_6K", "_4K"
    ]:
        if clean.to_upper().ends_with(suffix):
            clean = clean.left(clean.length() - suffix.length())

    var key := clean.to_upper()

    if SCENE_TITLES.has(key):
        return str(SCENE_TITLES[key])

    return clean.replace("_", " ").strip_edges()

func _format_scene_time(seconds: float) -> String:
    var total := maxi(0, int(floor(seconds)))
    var hours := int(floor(float(total) / 3600.0))
    var minutes := int(floor(float(total % 3600) / 60.0))
    var secs := total % 60

    if hours > 0:
        return "%d:%02d:%02d" % [hours, minutes, secs]

    return "%d:%02d" % [minutes, secs]

func _scene_controller_status(host: Node3D) -> String:
    if not host.video:
        return "No Scene Selected"

    var video = host.video

    var uri: String = str(video.local_uri)
    var title := _official_scene_title(uri)

    if _opening or not _duration_known:
        return title + "\nPreparing Scene"

    var duration := float(video.control.duration_ms) / 1000.0
    var position := float(video.control.observed_position_ms) / 1000.0

    if duration <= 0.0:
        return title

    position = clampf(position, 0.0, duration)

    var message := (
        title
        + "\nVideo: "
        + _format_scene_time(position)
        + " / "
        + _format_scene_time(duration)
    )

    if not engine.automatic:
        message += "\nContinuous Loop"

    elif engine.requires_loop(engine.original_duration):

        var target: float = engine.target_duration(
            engine.original_duration
        )

        var elapsed: float = clampf(
            engine.elapsed, 0.0, target
        )

        message += (
            "\nSession: "
            + _format_scene_time(elapsed)
            + " / "
            + _format_scene_time(target)
        )

    return message


# REALMSHUFFLE_FINAL_REFINEMENTS

const RealmGeometry = preload("res://scripts/video_geometry.gd")

var _current_music_path := ""
var _video_only_paused := false
var _guide_rows: Dictionary = {}
var _guide_roots: Dictionary = {}

func _enforce_vr180(video) -> void:
    # Only enforce the format on RealmShuffle's dedicated library.
    if not str(video.local_uri).uri_decode().contains(
        "/Movies/RealmShuffle/Videos/"
    ):
        return

    var corrected := false

    if video.geometry != RealmGeometry.Geometry.HALF_EQUIRECT:
        video.set_projection(RealmGeometry.Geometry.HALF_EQUIRECT)
        corrected = true

    if video.stereo_layout() != 1:
        video.set_stereo_layout(1)
        corrected = true

    if video.swap_eyes:
        video.toggle_eye_order()
        corrected = true

    if video.viewing_eye != 0:
        video.set_viewing_eye(0)
        corrected = true

    if corrected:
        print("[RealmShuffle Projection] Corrected to VR180 SBS LR")

func next_music_track() -> void:
    if not active:
        return

    _usage_music_navigation("manual_next")

    _scene_sync_enabled = false
    _sync_loaded_uri = ""
    _sync_track_path = ""
    _sync_force_seek = false
    print("[RealmShuffle Sync] Random music mode")

    var host := _host_ref.get_ref() as Node3D

    if not is_instance_valid(host):
        return

    if not is_instance_valid(_music_player):
        _music_initialize(host)
        return

    if _music_files.is_empty():
        _music_scan()
        return

    _music_next()

    print(
        "[RealmShuffle Audio] Manual music selection: ",
        _music_display_title()
    )

func _music_display_title() -> String:
    if _current_music_path.is_empty():
        return "No Music Playing"

    var filename := _current_music_path.get_file().get_basename()
    var parts := filename.split("__", false, 1)

    if parts.size() == 2:
        var key: String = parts[0].to_upper()

        if SCENE_TITLES.has(key):
            var title: String = str(SCENE_TITLES[key])
            var variant: String = parts[1].to_lower()

            if variant.contains("alternative"):
                title += " - Alternative"
            elif variant.contains("mira"):
                title += " - Mira"

            return title

    return filename.replace("_", " ").strip_edges()


# REALMSHUFFLE_FIXED_ROW_RENDERER

const GUIDE_WHITE_SIZE := 28
const GUIDE_COLOR_SIZE := 30
const GUIDE_PIXEL_SIZE := 0.00045
const GUIDE_ROW_SPACING := 0.0175

func _guide_root(base: Label3D, side: String) -> Node3D:

    if _guide_roots.has(side):

        var existing: Node3D = _guide_roots[side]

        if is_instance_valid(existing):
            return existing

    var root := Node3D.new()

    root.name = "RealmShuffleGuideRows_" + side
    root.position = base.position

    base.get_parent().add_child(root)

    _guide_roots[side] = root

    print(
        "[RealmShuffle Labels] Fixed-row guide created: ",
        side
    )

    return root

func _guide_row(
    root: Node3D,
    side: String,
    index: int
) -> Label3D:

    var key := side + "_" + str(index)

    if _guide_rows.has(key):

        var existing: Label3D = _guide_rows[key]

        if is_instance_valid(existing):
            return existing

    var row := Label3D.new()

    row.name = "Row_" + str(index)
    row.text = ""
    row.font_size = GUIDE_WHITE_SIZE
    row.pixel_size = GUIDE_PIXEL_SIZE
    row.outline_size = 7

    row.modulate = Color.WHITE

    row.outline_modulate = Color(
        0.015, 0.02, 0.035, 1.0
    )

    row.shaded = false
    row.no_depth_test = true
    row.render_priority = 11

    # The parent handles camera alignment.
    # Individual rows must not billboard independently.

    row.billboard = BaseMaterial3D.BILLBOARD_DISABLED

    row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    row.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    root.add_child(row)

    _guide_rows[key] = row

    return row

func _render_colored_guide(
    base: Label3D,
    message: String,
    side: String
) -> void:

    var root := _guide_root(base, side)

    if not is_instance_valid(root):
        return

    # Preserve the existing visibility rules.
    var show_guide := base.visible

    base.text = ""
    base.visible = false

    root.visible = show_guide

    if not show_guide:
        return

    # Rotate the entire guide as a single unit.
    # This keeps every row in the same readable plane.

    var camera := root.get_viewport().get_camera_3d()

    if is_instance_valid(camera):

        var camera_basis: Basis = (
            camera.global_transform.basis.orthonormalized()
        )

        root.global_basis = camera_basis

    var lines := message.split("\n")

    var top := (
        float(lines.size() - 1)
        * GUIDE_ROW_SPACING
        * 0.5
    )

    for i in range(lines.size()):

        var row := _guide_row(root, side, i)

        var tint := Color.WHITE
        var size := GUIDE_WHITE_SIZE

        if side == "left":

            if i == 3:

                # Binaural frequency descriptor.
                tint = Color(0.45, 0.90, 0.82, 1.0)
                size = GUIDE_COLOR_SIZE

            elif i == 7:

                # Current music title.
                tint = Color(0.96, 0.84, 0.55, 1.0)
                size = GUIDE_COLOR_SIZE

        elif i == 2:

            # Current scene title.
            tint = Color(0.78, 0.68, 1.0, 1.0)
            size = GUIDE_COLOR_SIZE

        row.position = Vector3(
            0.0,
            top - float(i) * GUIDE_ROW_SPACING,
            0.0
        )

        row.modulate = tint
        row.font_size = size
        row.visible = true

        if row.text != lines[i]:
            row.text = lines[i]

    # Hide unused rows when switching between short
    # scenes, long scenes and continuous playback.

    for i in range(lines.size(), 16):

        var key := side + "_" + str(i)

        if _guide_rows.has(key):

            var unused: Label3D = _guide_rows[key]

            if is_instance_valid(unused):
                unused.visible = false


# REALMSHUFFLE_INDEPENDENT_PAUSE

func _toggle_video_only(host: Node3D) -> void:

    var was_playing: bool = host.video.requested_play

    if was_playing:
        _video_only_paused = true
        host.video.toggle_play()

        print(
            "[RealmShuffle Pause] Video paused; audio continues"
        )
    else:
        _video_only_paused = false
        host.video.toggle_play()

        print("[RealmShuffle Pause] Video resumed")

func toggle_full_pause(host: Node3D) -> void:

    if _video_only_paused:

        # Video is already frozen. Pause remaining audio.
        _video_only_paused = false

        print("[RealmShuffle Pause] All playback paused")
        return

    _video_only_paused = false
    host.video.toggle_play()

    print(
        "[RealmShuffle Pause] Full playback ",
        "resumed" if host.video.requested_play else "paused"
    )


# REALMSHUFFLE_CONTINUOUS_ZOOM

var _session_zoom := 0.0
var _zoom_initialized := false
var _orientation_initialized := false
var _session_view_basis := Basis.IDENTITY
var _session_view_yaw := 0.0
var _session_view_pitch := 0.0
var _session_view_roll := 0.0

func _capture_session_zoom(host: Node3D) -> void:
    if not _zoom_initialized:
        _session_zoom = 0.0
        return

    if not host.video:
        return

    if str(host.video.local_uri).is_empty():
        return

    var current := float(host.video.view_zoom)

    if not is_finite(current):
        return

    _session_zoom = clampf(current, -0.5, 0.6)
    _capture_session_orientation(host)

    print(
        "[RealmShuffle Zoom] Captured: ",
        _session_zoom
    )

func _restore_session_zoom(host: Node3D) -> void:
    if not host.video:
        return

    if str(host.video.local_uri) != _expected_uri:
        return

    _restore_session_orientation(host)

    if host.video.set_immersive_adjustment(
        "view_zoom", _session_zoom
    ):
        _zoom_initialized = true

        print(
            "[RealmShuffle Zoom] Restored: ",
            _session_zoom
        )


# REALMSHUFFLE_PEACEFUL_TRANSITIONS

const PEACEFUL_TRANSITIONS: Array[Dictionary] = [
    {
        "name": "Soft Fade",
        "out": 0.8,
        "in": 1.2,
        "color": Color(0.0, 0.0, 0.0),
        "weight": 30
    },
    {
        "name": "Deep Dissolve",
        "out": 1.8,
        "in": 2.2,
        "color": Color(0.0, 0.0, 0.0),
        "weight": 25
    },
    {
        "name": "Midnight Drift",
        "out": 1.4,
        "in": 1.8,
        "color": Color(0.063, 0.106, 0.188),
        "weight": 20
    },
    {
        "name": "Twilight Mist",
        "out": 1.6,
        "in": 2.0,
        "color": Color(0.141, 0.102, 0.188),
        "weight": 15
    },
    {
        "name": "Ocean Stillness",
        "out": 1.5,
        "in": 1.9,
        "color": Color(0.063, 0.169, 0.176),
        "weight": 10
    }
]

var _last_transition := -1
var _selected_fade_out := 0.8
var _selected_fade_in := 1.2
var _selected_fade_color := Color.BLACK

func _select_peaceful_transition(
    startup: bool
) -> void:

    var selected := 0

    if not startup:

        var total_weight := 0

        for i in range(PEACEFUL_TRANSITIONS.size()):
            if i != _last_transition:
                total_weight += int(
                    PEACEFUL_TRANSITIONS[i]["weight"]
                )

        var roll := randi_range(1, total_weight)

        for i in range(PEACEFUL_TRANSITIONS.size()):

            if i == _last_transition:
                continue

            roll -= int(
                PEACEFUL_TRANSITIONS[i]["weight"]
            )

            if roll <= 0:
                selected = i
                break

    _last_transition = selected

    var style: Dictionary = PEACEFUL_TRANSITIONS[selected]

    _selected_fade_out = float(style["out"])
    _selected_fade_in = float(style["in"])
    _selected_fade_color = style["color"]

    print(
        "[RealmShuffle Transition] ",
        style["name"],
        " | Fade out: ",
        _selected_fade_out,
        "s | Fade in: ",
        _selected_fade_in,
        "s"
    )


# REALMSHUFFLE_PERSISTENT_ORIENTATION

func _capture_session_orientation(host: Node3D) -> void:
    if not host.video:
        return

    var video = host.video

    if video.geometry == RealmGeometry.Geometry.FLAT:
        return

    if str(video.local_uri).is_empty():
        return

    _session_view_basis = video._view_basis
    _session_view_yaw = float(video.view_yaw)
    _session_view_pitch = float(video.view_pitch)
    _session_view_roll = float(video.screen_rotation)

    _orientation_initialized = true

    print(
        "[RealmShuffle Orientation] Captured",
        " | Basis: ", _session_view_basis,
        " | Yaw: ", rad_to_deg(_session_view_yaw),
        " | Pitch: ", rad_to_deg(_session_view_pitch),
        " | Roll: ", _session_view_roll
    )

func _restore_session_orientation(host: Node3D) -> void:
    if not host.video:
        return

    var video = host.video

    if str(video.local_uri) != _expected_uri:
        return

    if video.geometry == RealmGeometry.Geometry.FLAT:
        return

    # The first scene establishes the initial viewing direction.
    if not _orientation_initialized:
        _capture_session_orientation(host)

        print(
            "[RealmShuffle Orientation] Initial center established"
        )
        return

    # Subsequent scenes inherit the previous viewing direction.
    # Never sample the current headset gaze here.

    video._view_basis = _session_view_basis
    video.view_yaw = _session_view_yaw
    video.view_pitch = _session_view_pitch
    video.screen_rotation = _session_view_roll

    video._center_on_view()

    print(
        "[RealmShuffle Orientation] Restored",
        " | Basis: ", _session_view_basis,
        " | Yaw: ", rad_to_deg(_session_view_yaw),
        " | Pitch: ", rad_to_deg(_session_view_pitch),
        " | Roll: ", _session_view_roll
    )


# REALMSHUFFLE_SCENE_SYNC

var _scene_sync_enabled := false
var _sync_loaded_uri := ""
var _sync_track_path := ""
var _sync_missing := false

var _sync_bags: Dictionary = {}
var _sync_last_tracks: Dictionary = {}

var _sync_loop_count := 0
var _sync_last_position := -1.0
var _sync_clock := 0.0
var _sync_force_seek := false
var _sync_last_paused := false


func _sync_status_text() -> String:

    if not _scene_sync_enabled:
        return "Scene Sync"

    if _sync_missing:
        return "Sync: No Match"

    return "Scene Sync ON"


func _scene_match_key(uri: String) -> String:

    var filename := uri.uri_decode().get_file().get_basename()

    var key := filename

    for suffix in [
        "_180_LR",
        "_180_RL",
        "_180",
        "_360_LR",
        "_360"
    ]:
        if key.to_upper().ends_with(suffix):
            key = key.substr(
                0,
                key.length() - suffix.length()
            )
            break

    key = key.to_upper()

    if key == "DISSOLVE":
        return "DIS"

    return key


func _matching_music(key: String) -> Array[String]:

    var result: Array[String] = []

    for path in _music_files:

        var filename: String = path.get_file().get_basename()

        var parts := filename.split("__", false, 1)

        if parts.size() != 2:
            continue

        if parts[0].to_upper() == key:
            result.append(path)

    result.sort()

    return result


func _next_matching_music(key: String) -> String:

    var candidates := _matching_music(key)

    if candidates.is_empty():
        return ""

    var bag: Array = _sync_bags.get(key, [])

    # Remove unavailable tracks from the existing cycle.
    bag = bag.filter(
        func(path): return candidates.has(str(path))
    )

    if bag.is_empty():

        bag.assign(candidates)
        bag.shuffle()

        var previous: String = str(
            _sync_last_tracks.get(key, "")
        )

        if bag.size() > 1 and str(bag[0]) == previous:

            var first: String = str(bag.pop_front())
            bag.append(first)

    var selected: String = str(bag.pop_front())

    _sync_bags[key] = bag
    _sync_last_tracks[key] = selected

    return selected


func _load_sync_stream(path: String) -> AudioStream:

    match path.get_extension().to_lower():

        "ogg":
            return AudioStreamOggVorbis.load_from_file(path)

        "mp3":
            return AudioStreamMP3.load_from_file(path)

        "wav":
            return AudioStreamWAV.load_from_file(path)

    return null


func _sync_video_seconds(host: Node3D) -> float:

    var position := maxf(
        0.0,
        float(host.video.control.observed_position_ms) / 1000.0
    )

    var duration := maxf(
        0.0,
        float(host.video.control.duration_ms) / 1000.0
    )

    return (
        float(_sync_loop_count) * duration
        + position
    )


func _sync_audio_target(host: Node3D) -> float:

    if not is_instance_valid(_music_player):
        return 0.0

    if _music_player.stream == null:
        return 0.0

    var length: float = _music_player.stream.get_length()

    if length <= 0.0:
        return 0.0

    return fposmod(
        _sync_video_seconds(host),
        length
    )


func _seek_matched_audio(host: Node3D) -> void:

    if not is_instance_valid(_music_player):
        return

    if _music_player.stream == null:
        return

    var target := _sync_audio_target(host)

    if _music_player.playing:
        _music_player.seek(target)
    else:
        _music_player.play(target)

    print(
        "[RealmShuffle Sync] Aligned audio",
        " | Video session: ", _sync_video_seconds(host),
        " | Audio position: ", target
    )


func _select_matched_audio(host: Node3D) -> void:

    if not is_instance_valid(_music_player):
        return

    var uri: String = str(host.video.local_uri)

    if uri.is_empty():
        return

    var key := _scene_match_key(uri)
    var candidates := _matching_music(key)

    _sync_loaded_uri = uri
    _sync_missing = candidates.is_empty()

    if _sync_missing:

        # The user's matching preference remains active.
        # An unmatched scene can use independent music.

        var was_matched := not _sync_track_path.is_empty()

        _sync_track_path = ""

        if was_matched or not _music_player.playing:
            _music_next()

        print(
            "[RealmShuffle Sync] No matching soundtrack: ",
            key
        )

        return

    # Try each available match at most once.
    for attempt in range(candidates.size()):

        var path := _next_matching_music(key)

        if path.is_empty():
            break

        if (
            path == _current_music_path
            and _music_player.stream != null
        ):

            _sync_track_path = path
            _sync_force_seek = false

            if _music_player.stream is AudioStreamOggVorbis:
                _music_player.stream.loop = true
            elif _music_player.stream is AudioStreamMP3:
                _music_player.stream.loop = true
            elif _music_player.stream is AudioStreamWAV:
                _music_player.stream.loop_mode = AudioStreamWAV.LOOP_FORWARD

            _seek_matched_audio(host)

            print(
                "[RealmShuffle Sync] Existing soundtrack aligned: ",
                path.get_file()
            )

            return

        var stream := _load_sync_stream(path)

        if stream == null:

            print(
                "[RealmShuffle Sync] Cannot load ",
                path
            )

            continue

        if stream is AudioStreamOggVorbis:
            stream.loop = true
        elif stream is AudioStreamMP3:
            stream.loop = true
        elif stream is AudioStreamWAV:
            stream.loop_mode = AudioStreamWAV.LOOP_FORWARD

        _music_player.stop()
        _music_player.stream = stream

        _current_music_path = path
        _sync_track_path = path

        var target := _sync_audio_target(host)

        _music_player.play(target)

        _music_player.stream_paused = (
            not host.wearer_present
            or (
                not host.video.requested_play
                and not _video_only_paused
            )
        )

        _sync_force_seek = false

        print(
            "[RealmShuffle Sync] Matched soundtrack",
            " | Scene: ", key,
            " | Track: ", path.get_file(),
            " | Duration: ", stream.get_length(),
            " | Position: ", target,
            " | Remaining variants: ",
            _sync_bags.get(key, []).size()
        )

        return

    _sync_missing = true
    _sync_track_path = ""
    _music_next()


func sync_current_scene() -> void:

    var host := _host_ref.get_ref() as Node3D

    if not is_instance_valid(host) or not host.video:
        return

    _usage_music_navigation("sync_requested")
    _scene_sync_enabled = true

    if not is_instance_valid(_music_player):
        _music_initialize(host)

    if (
        _opening
        or transition_active
        or host.video.control.duration_ms <= 0
    ):

        _sync_loaded_uri = ""
        _sync_force_seek = true

        print(
            "[RealmShuffle Sync] Waiting for scene readiness"
        )

        return

    _select_matched_audio(host)


func _on_music_finished() -> void:

    _usage_write("music", "natural_end", {
        "media_id": _usage_music_id,
        "active_seconds": _usage_music_seconds,
        "mode": _usage_music_mode()
    })
    _usage_music_reason = "natural_complete"

    if (
        _scene_sync_enabled
        and not _sync_missing
        and not _sync_track_path.is_empty()
    ):

        var host := _host_ref.get_ref() as Node3D

        if is_instance_valid(host) and host.video:
            _seek_matched_audio(host)

        return

    _music_next()


func _scene_sync_tick(host: Node3D, delta: float) -> void:

    if not host.video:
        return

    if _opening or not _duration_known:
        return

    var video = host.video

    var uri: String = str(video.local_uri)

    if uri.is_empty() or uri != _expected_uri:
        return

    var duration := float(video.control.duration_ms) / 1000.0

    if duration <= 0.0:
        return

    var position := maxf(
        0.0,
        float(video.control.observed_position_ms) / 1000.0
    )

    # Observe video loops even while random music is active.
    # A later trigger press can therefore synchronize into
    # the accumulated session rather than only the first loop.

    var seek_busy: bool = (
        video.control.pending
        or video.control.in_flight > 0
    )

    var jumped := false

    if not seek_busy:

        if _sync_last_position >= 0.0:

            var movement := position - _sync_last_position

            # Natural wrap from the end to the beginning.
            if (
                _sync_last_position >= duration - 1.5
                and position <= 1.5
                and duration > 3.0
            ):
                _sync_loop_count += 1

                print(
                    "[RealmShuffle Sync] Video loop ",
                    _sync_loop_count
                )

            elif absf(movement) > 1.5:
                jumped = true

        _sync_last_position = position

    if not _scene_sync_enabled:
        return

    # Wait until the new video is ready before selecting
    # its corresponding audio.

    if _sync_loaded_uri != uri:

        if video.media.state == "playing":
            _select_matched_audio(host)

        return

    if _sync_missing or _sync_track_path.is_empty():
        return

    if not is_instance_valid(_music_player):
        return

    if seek_busy:
        _sync_force_seek = true
        return

    var paused: bool = not video.requested_play

    if paused:

        # Video-only pause must not interrupt the music.
        _sync_last_paused = true
        return

    if not host.wearer_present:
        return

    if _sync_last_paused:

        _sync_last_paused = false
        _sync_force_seek = true

    if jumped:
        _sync_force_seek = true

    _sync_clock += delta

    if _sync_force_seek:

        _sync_force_seek = false
        _sync_clock = 0.0

        _seek_matched_audio(host)
        return

    # Check for significant drift periodically rather
    # than issuing constant audio seek commands.

    if _sync_clock >= 3.0:

        _sync_clock = 0.0

        if _music_player.stream == null:
            return

        var length: float = _music_player.stream.get_length()

        if length <= 0.0:
            return

        var target := _sync_audio_target(host)
        var actual := _music_player.get_playback_position()

        var drift := absf(target - actual)

        drift = minf(
            drift,
            absf(length - drift)
        )

        if drift > 0.85:
            _seek_matched_audio(host)


# REALMSHUFFLE_QUIET_LOOPING

const QUIET_LOOP_MARGIN_MS := 350

var _quiet_loop_pending := false
var _quiet_loop_wait := 0.0


func _quiet_end_tick(host: Node3D, delta: float) -> void:

    if not active or not _duration_known:
        return

    if transition_active or _opening:
        return

    if not host.wearer_present:
        return

    var video = host.video

    if not video.requested_play:
        return

    if video.media.state != "playing":
        return

    if not video.media.error.is_empty():
        return

    if str(video.local_uri) != _expected_uri:
        return

    var duration: int = int(video.control.duration_ms)
    var position: int = int(video.control.observed_position_ms)

    if duration < 3000:
        return

    if _quiet_loop_pending:

        _quiet_loop_wait += delta

        if position < 2000:
            _quiet_loop_pending = false
            _quiet_loop_wait = 0.0

            print("[RealmShuffle Loop] Quiet restart confirmed")

        elif _quiet_loop_wait >= 3.0:

            _quiet_loop_pending = false
            _quiet_loop_wait = 0.0

            print("[RealmShuffle Loop] Native fallback available")

        else:
            return

    if video.control.pending or video.control.in_flight > 0:
        return

    if video.stick_scrubbing:
        return

    var remaining: int = duration - position

    if remaining < 0:
        return

    # Short adaptive scenes and continuous-loop mode:
    # restart before reaching the native EOF state.

    if video.loop_enabled:

        if remaining <= QUIET_LOOP_MARGIN_MS:

            _quiet_loop_pending = true
            _quiet_loop_wait = 0.0

            print(
                "[RealmShuffle Loop] Pre-end restart",
                " | Remaining ms: ", remaining
            )

            video.seek_absolute(0)

        return

    # Long scenes: use the existing peaceful fade
    # shortly before reaching EOF.

    if engine.automatic:

        if remaining <= 2400:

            print(
                "[RealmShuffle Loop] Pre-end scene transition",
                " | Remaining ms: ", remaining
            )

            next_scene("natural_complete")


# REALMSHUFFLE_FRAME_HOLD

var _frame_hold_last_route := ""
var _frame_hold_was_frozen := false
var _frame_hold_was_waiting := false
var _frame_hold_started_ms := 0


func _frame_hold_diagnostics(host: Node3D) -> void:

    if not active or not host.video:
        return

    var video = host.video

    if video.layer_controller:

        var route: String = str(
            video.layer_controller.route
        )

        if route != _frame_hold_last_route:

            _frame_hold_last_route = route

            print(
                "[RealmShuffle FrameHold] Route: ",
                route,
                " | Surface requested: ",
                video.surface_requested
            )

    var frozen: bool = video._is_frozen()

    if frozen != _frame_hold_was_frozen:

        _frame_hold_was_frozen = frozen

        if frozen:

            print(
                "[RealmShuffle FrameHold] Frame preserved"
            )

        else:

            print(
                "[RealmShuffle FrameHold] Frame released"
            )

    var waiting: bool = video.waiting_for_first_frame()

    if waiting != _frame_hold_was_waiting:

        _frame_hold_was_waiting = waiting

        if waiting:

            _frame_hold_started_ms = Time.get_ticks_msec()

            print(
                "[RealmShuffle FrameHold] Waiting",
                " | Frozen: ", frozen,
                " | Surface: ", video.surface_requested
            )

        else:

            print(
                "[RealmShuffle FrameHold] Frame ready",
                " | Wait ms: ",
                Time.get_ticks_msec() - _frame_hold_started_ms
            )




# PHASE65_OVERLAY_LAYOUT
# REALMSHUFFLE_PERFORMANCE_MONITOR

var _performance_visible := false
var _performance_panel: Node3D
var _performance_label: Label3D
var _performance_elapsed := 0.0
var _performance_last_ms := 0
var _performance_last_frames := -1
var _performance_last_decoder := -1
var _performance_last_output := -1
var _performance_session := -1
var _performance_log_elapsed := 0.0


func _performance_create(host: Node3D) -> void:
    if is_instance_valid(_performance_panel):
        return

    if not is_instance_valid(host.xr_camera):
        return

    _performance_panel = Node3D.new()
    _performance_panel.name = "RealmShufflePerformance"
    host.xr_camera.add_child(_performance_panel)

    _performance_panel.position = Vector3(0.0, -0.06, -1.15)

    var background := MeshInstance3D.new()
    var quad := QuadMesh.new()
    quad.size = Vector2(0.96, 0.72)
    background.mesh = quad

    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.no_depth_test = true
    material.render_priority = 121
    material.albedo_color = Color(0.025, 0.045, 0.065, 0.92)

    background.material_override = material
    _performance_panel.add_child(background)

    _performance_label = Label3D.new()
    _performance_label.font_size = 27
    _performance_label.pixel_size = 0.00085
    _performance_label.outline_size = 3
    _performance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    _performance_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
    _performance_label.no_depth_test = true
    _performance_label.render_priority = 123
    _performance_label.outline_render_priority = 122
    _performance_label.modulate = Color(0.76, 1.0, 0.93)

    _performance_label.position = Vector3(-0.43, 0.32, 0.005)
    _performance_panel.add_child(_performance_label)

    _performance_panel.visible = false


func _toggle_performance_overlay(host: Node3D) -> void:
    _performance_create(host)

    if not is_instance_valid(_performance_panel):
        return

    _performance_visible = not _performance_visible
    _performance_panel.visible = _performance_visible

    _performance_elapsed = 1.0
    _performance_last_frames = -1
    _performance_last_decoder = -1
    _performance_last_output = -1
    _performance_session = -1
    _performance_last_ms = Time.get_ticks_msec()
    _performance_log_elapsed = 0.0

    print("[RealmShuffle Performance] Visible: ", _performance_visible)


func _performance_counter(data: Dictionary, keys: Array) -> int:
    for key in keys:
        if data.has(key):
            var value: Variant = data[key]

            if value is int or value is float:
                return maxi(-1, int(value))

            if value is String and value.is_valid_int():
                return maxi(-1, int(value))

    return -1


func _performance_counter_text(value: int) -> String:
    return str(value) if value >= 0 else "N/A"


func _performance_rate_text(
    value: int,
    previous: int,
    interval: float
) -> String:
    if value < 0 or previous < 0 or value < previous or interval <= 0.0:
        return "N/A"

    return "%.1f/s" % (float(value - previous) / interval)


func _performance_tick(host: Node3D, delta: float) -> void:
    if not _performance_visible:
        return

    if not is_instance_valid(_performance_panel):
        return

    _performance_panel.visible = active and host.wearer_present

    if not _performance_panel.visible:
        _performance_last_ms = Time.get_ticks_msec()
        _performance_last_frames = -1
        _performance_last_decoder = -1
        _performance_last_output = -1
        return

    _performance_elapsed += delta
    _performance_log_elapsed += delta

    if _performance_elapsed < 0.5:
        return

    _performance_elapsed = 0.0

    var now := Time.get_ticks_msec()
    var interval := maxf(0.001, float(now - _performance_last_ms) / 1000.0)
    _performance_last_ms = now

    var video = host.video
    var media = video.media
    var details: Dictionary = media.playback.get("details", {})
    var session: int = int(media.session_id)

    if session != _performance_session:
        _performance_session = session
        _performance_last_frames = -1
        _performance_last_decoder = -1
        _performance_last_output = -1

    var frames: int = int(media.frame_counter)
    var presented := _performance_rate_text(
        frames, _performance_last_frames, interval
    )

    var decoder := _performance_counter(
        details,
        ["decoder_frame_drop_count", "decoder_drops", "decoder-frame-drop-count"]
    )

    var output := _performance_counter(
        details,
        ["frame_drop_count", "vo_drops", "output_drops", "frame-drop-count"]
    )

    var decoder_rate := _performance_rate_text(
        decoder, _performance_last_decoder, interval
    )

    var output_rate := _performance_rate_text(
        output, _performance_last_output, interval
    )

    _performance_last_frames = frames
    _performance_last_decoder = decoder
    _performance_last_output = output

    var fps := float(Engine.get_frames_per_second())
    var frame_ms := 1000.0 / maxf(fps, 1.0)

    var refresh := "N/A"
    var requested := "N/A"

    if host.display:
        requested = str(host.display.performance_levels)

        var xr = host.display.xr

        if xr is OpenXRInterface and xr.is_initialized():
            refresh = "%.1f Hz" % float(xr.display_refresh_rate)

    var battery := "N/A"
    var power := "N/A"

    if Engine.has_singleton("QuestPlayer"):
        var plugin := Engine.get_singleton("QuestPlayer")

        if plugin.has_method("device_status"):
            var status: Variant = JSON.parse_string(
                str(plugin.device_status())
            )

            if status is Dictionary:
                var level := int(status.get("level", -1))

                if level >= 0:
                    battery = "%d%%" % level

                if status.has("plugged") or status.has("charging"):
                    if bool(status.get("charging", false)):
                        power = "Charging"
                    elif bool(status.get("plugged", false)):
                        power = "Connected"
                    else:
                        power = "Battery"

    var resolution := "%d x %d" % [
        int(media.format.get("width", 0)),
        int(media.format.get("height", 0))
    ]

    var route := "N/A"

    if video.layer_controller:
        route = str(video.layer_controller.route)

    var title := str(video.display_name)

    if title.length() > 36:
        title = title.left(33) + "..."

    var decoder_text := str(media.decoder)

    if decoder_text.length() > 38:
        decoder_text = decoder_text.left(35) + "..."

    var lines: Array[String] = [
        "REALMSHUFFLE PERFORMANCE",
        title,
        " ",
        "App FPS: %.1f   |   %.1f ms" % [fps, frame_ms],
        "Display: " + refresh,
        "Presented video: " + presented,
        "Resolution: " + resolution,
        "Decoder: " + decoder_text,
        " ",
        "Decoder drops: " + _performance_counter_text(decoder)
            + "  (" + decoder_rate + ")",
        "Output drops: " + _performance_counter_text(output)
            + "  (" + output_rate + ")",
        "CPU/GPU request: " + requested,
        "Battery: " + battery + "  |  " + power,
        "Render route: " + route,
        "Frame hold: " + ("Active" if video._is_frozen() else "Inactive"),
        "State: " + str(media.state),
        " ",
        "LEFT GRIP: Hide performance"
    ]

    var font := _performance_label.font

    if font == null:
        font = ThemeDB.fallback_font

    var widest := 0.0

    for line in lines:
        widest = maxf(
            widest,
            font.get_string_size(
                line,
                HORIZONTAL_ALIGNMENT_LEFT,
                -1,
                _performance_label.font_size
            ).x
        )

    _performance_label.pixel_size = minf(
        0.00085,
        0.86 / maxf(widest, 1.0)
    )

    _performance_label.text = "\n".join(lines)

    if _performance_log_elapsed >= 5.0:
        _performance_log_elapsed = 0.0

        print(
            "[RealmShuffle Performance] ",
            JSON.stringify({
                "scene": title,
                "app_fps": fps,
                "frame_interval_ms": frame_ms,
                "display": refresh,
                "presented_rate": presented,
                "resolution": resolution,
                "decoder": media.decoder,
                "decoder_drops": decoder,
                "decoder_drop_rate": decoder_rate,
                "output_drops": output,
                "output_drop_rate": output_rate,
                "performance_request": requested,
                "battery": battery,
                "power": power,
                "route": route,
                "frozen": video._is_frozen(),
                "state": media.state,
                "native_detail_keys": details.keys()
            })
        )


# REALMSHUFFLE_USAGE_JOURNAL

const USAGE_DIR := "/sdcard/Movies/RealmShuffle/Logs"
const USAGE_CHECKPOINT_SECONDS := 30.0

var _usage_ready := false
var _usage_warned := false
var _usage_session := ""
var _usage_sequence := 0

var _usage_video_id := ""
var _usage_video_uri := ""
var _usage_video_session := -1
var _usage_video_seconds := 0.0
var _usage_video_duration := 0.0
var _usage_video_position := 0.0
var _usage_video_reason := ""
var _usage_video_destination := ""

var _usage_music_id := ""
var _usage_music_seconds := 0.0
var _usage_music_duration := 0.0
var _usage_music_position := 0.0
var _usage_music_reason := ""
var _usage_music_previous_mode := ""

var _usage_checkpoint := 0.0


func _usage_initialize() -> bool:
    if _usage_ready:
        return true

    var result := DirAccess.make_dir_recursive_absolute(
        USAGE_DIR
    )

    if result != OK:
        if not _usage_warned:
            print("[RealmShuffle Usage] Log directory unavailable: ", result)
            _usage_warned = true
        return false

    _usage_session = (
        str(Time.get_unix_time_from_system())
        + "-"
        + str(Time.get_ticks_usec())
    )

    _usage_ready = true

    print("[RealmShuffle Usage] Persistent journal initialized")

    return true


func _usage_write(
    kind: String,
    event: String,
    fields: Dictionary
) -> void:

    if not _usage_initialize():
        return

    _usage_sequence += 1

    var record := fields.duplicate(true)

    record["schema"] = 1
    record["session_id"] = _usage_session
    record["sequence"] = _usage_sequence
    record["timestamp_unix"] = Time.get_unix_time_from_system()
    record["monotonic_ms"] = Time.get_ticks_msec()
    record["event"] = event
    record["kind"] = kind

    var filename := (
        "Video-Events.jsonl"
        if kind == "video"
        else "Music-Events.jsonl"
    )

    var path := USAGE_DIR.path_join(filename)

    var mode := (
        FileAccess.READ_WRITE
        if FileAccess.file_exists(path)
        else FileAccess.WRITE
    )

    var file := FileAccess.open(path, mode)

    if file == null:
        print("[RealmShuffle Usage] Cannot write: ", path)
        return

    file.seek_end()
    file.store_line(JSON.stringify(record))
    file.flush()
    file.close()

    if event != "checkpoint":
        print(
            "[RealmShuffle Usage] ",
            kind, " | ", event, " | ",
            record.get("media_id", "")
        )


func _usage_media_id(path: String) -> String:
    return path.uri_decode().get_file().to_lower()


func _usage_fraction(
    seconds: float,
    duration: float
) -> float:

    if duration <= 0.0:
        return 0.0

    return clampf(seconds / duration, 0.0, 1.0)


func _usage_music_mode() -> String:
    if _scene_sync_enabled and not _sync_track_path.is_empty():
        return "matched"

    return "random"


func _usage_video_fields() -> Dictionary:
    return {
        "media_id": _usage_video_id,
        "uri": _usage_video_uri,
        "active_seconds": _usage_video_seconds,
        "natural_duration": _usage_video_duration,
        "position_seconds": _usage_video_position,
        "exposure_fraction": _usage_fraction(
            _usage_video_seconds,
            _usage_video_duration
        )
    }


func _usage_music_fields() -> Dictionary:
    return {
        "media_id": _usage_music_id,
        "active_seconds": _usage_music_seconds,
        "natural_duration": _usage_music_duration,
        "position_seconds": _usage_music_position,
        "exposure_fraction": _usage_fraction(
            _usage_music_seconds,
            _usage_music_duration
        ),
        "mode": _usage_music_previous_mode
    }


func _usage_video_navigation(
    destination: String,
    reason: String
) -> void:

    if destination.is_empty():
        return

    if destination == _usage_video_uri:
        return

    _usage_video_reason = reason
    _usage_video_destination = destination

    var fields := _usage_video_fields()

    fields["reason"] = reason
    fields["destination_id"] = _usage_media_id(destination)

    _usage_write("video", "navigation_requested", fields)


func _usage_music_navigation(reason: String) -> void:
    _usage_music_reason = reason

    var fields := _usage_music_fields()
    fields["reason"] = reason

    _usage_write("music", "navigation_requested", fields)


func _usage_tick(host: Node3D, delta: float) -> void:
    if not active:
        return

    var video = host.video

    # Ignore unusually large frame intervals so suspended
    # applications do not inflate viewing/listening time.

    var elapsed := clampf(delta, 0.0, 0.25)

    var uri: String = str(video.local_uri)
    var media_id := _usage_media_id(uri)
    var session: int = int(video.media.session_id)

    var ready: bool = (
        not uri.is_empty()
        and video.control.duration_ms > 0
        and video.media.state == "playing"
        and video.media.error.is_empty()
        and not video.waiting_for_first_frame()
    )

    if ready and (
        uri != _usage_video_uri
        or session != _usage_video_session
    ):

        var reason := "observed_selection"

        if uri == _usage_video_destination:
            reason = _usage_video_reason

        if not _usage_video_id.is_empty():

            var previous := _usage_video_fields()
            previous["reason"] = reason
            previous["destination_id"] = media_id

            _usage_write("video", "playback_end", previous)

        _usage_video_uri = uri
        _usage_video_id = media_id
        _usage_video_session = session
        _usage_video_seconds = 0.0
        _usage_video_duration = (
            float(video.control.duration_ms) / 1000.0
        )

        _usage_video_position = (
            float(video.control.observed_position_ms) / 1000.0
        )

        var started := _usage_video_fields()
        started["selection_reason"] = reason

        _usage_write("video", "playback_start", started)

        _usage_video_reason = ""
        _usage_video_destination = ""

    if ready and uri == _usage_video_uri:

        _usage_video_position = (
            float(video.control.observed_position_ms) / 1000.0
        )

        if (
            host.wearer_present
            and video.requested_play
            and not transition_active
            and not _opening
            and not video.control.pending
            and video.control.in_flight == 0
            and not video.stick_scrubbing
        ):
            _usage_video_seconds += elapsed

    if is_instance_valid(_music_player):

        var path: String = _current_music_path
        var music_id := _usage_media_id(path)

        if (
            _music_player.stream != null
            and _music_player.playing
            and not music_id.is_empty()
            and music_id != _usage_music_id
        ):

            if not _usage_music_id.is_empty():

                var ended := _usage_music_fields()

                ended["reason"] = (
                    _usage_music_reason
                    if not _usage_music_reason.is_empty()
                    else "automatic_change"
                )

                ended["destination_id"] = music_id

                _usage_write("music", "playback_end", ended)

            _usage_music_id = music_id
            _usage_music_seconds = 0.0
            _usage_music_duration = _music_player.stream.get_length()
            _usage_music_position = _music_player.get_playback_position()
            _usage_music_previous_mode = _usage_music_mode()

            var started_music := _usage_music_fields()

            started_music["selection_reason"] = (
                _usage_music_reason
                if not _usage_music_reason.is_empty()
                else "automatic"
            )

            _usage_write("music", "playback_start", started_music)

            _usage_music_reason = ""

        if (
            _music_player.playing
            and music_id == _usage_music_id
            and not music_id.is_empty()
        ):

            _usage_music_position = _music_player.get_playback_position()

            var current_mode := _usage_music_mode()

            if current_mode != _usage_music_previous_mode:

                _usage_write("music", "mode_changed", {
                    "media_id": music_id,
                    "previous_mode": _usage_music_previous_mode,
                    "mode": current_mode
                })

                _usage_music_previous_mode = current_mode
                _usage_music_reason = ""

            if (
                host.wearer_present
                and not _music_player.stream_paused
            ):
                _usage_music_seconds += elapsed

    _usage_checkpoint += elapsed

    if _usage_checkpoint >= USAGE_CHECKPOINT_SECONDS:

        _usage_checkpoint = 0.0

        if not _usage_video_id.is_empty():
            _usage_write(
                "video", "checkpoint", _usage_video_fields()
            )

        if not _usage_music_id.is_empty():
            _usage_write(
                "music", "checkpoint", _usage_music_fields()
            )
