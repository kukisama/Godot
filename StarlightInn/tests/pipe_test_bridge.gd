extends "res://scripts/azure_bridge.gd"
## Independent compile-time fake backend. Same transport as production.
var evidence: Dictionary = {}

func _receive(raw: Dictionary) -> void:
	if raw.get("kind") == "fixture_evidence":
		evidence = raw
	else:
		super._receive(raw)

func _allow_helper() -> bool:
	return true

func _helper_path() -> String:
	return ProjectSettings.globalize_path("res://qa/native-build/pipe-fixture.exe")