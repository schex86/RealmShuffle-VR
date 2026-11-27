extends RefCounted

const SHORT_THRESHOLD := 240.0
const EXTENDED_DURATION := 300.0

var threshold := SHORT_THRESHOLD
var extended_duration := EXTENDED_DURATION
var elapsed := 0.0
var original_duration := 0.0
var automatic := true

var order: Array[String] = []
var history: Array[String] = []
var cursor := -1
var current := ""

func target_duration(duration: float) -> float:
    if duration <= 0.0:
        return 0.0
    if duration < threshold:
        return extended_duration
    return duration

func requires_loop(duration: float) -> bool:
    return duration > 0.0 and duration < threshold

func begin_scene(duration: float) -> void:
    original_duration = duration
    elapsed = 0.0

func tick(delta: float, playing: bool) -> bool:
    if playing:
        elapsed += maxf(delta, 0.0)

    return (
        automatic
        and original_duration > 0.0
        and elapsed >= target_duration(original_duration)
    )

func configure(entries: Array[String]) -> void:
    order.clear()
    history.clear()
    cursor = -1
    current = ""

    for entry in entries:
        if not entry.is_empty() and not order.has(entry):
            order.append(entry)

    order.shuffle()

func reshuffle() -> void:
    order.shuffle()

    if order.size() > 1 and order[0] == current:
        var first: String = order.pop_front()
        order.append(first)

func next_scene() -> String:
    if order.is_empty():
        return ""

    if cursor + 1 < history.size():
        cursor += 1
        current = history[cursor]
        return current

    if order.size() == 1:
        current = order[0]
    else:
        var index := order.find(current)

        if index == order.size() - 1:
            reshuffle()
            index = -1

        current = order[index + 1]

    history.append(current)
    cursor = history.size() - 1
    return current

func previous_scene() -> String:
    if cursor <= 0:
        return current

    cursor -= 1
    current = history[cursor]
    return current
