class_name ConfigSettingsPersist
extends RefCounted
## Default persistence backend for PluginSettingsStore: reads and writes
## config_file.cfg via SingletonObject. Isolated in its own class so the store
## itself stays free of autoload references and remains unit-testable.


func read(section: String, key: String) -> Variant:
	return SingletonObject.get_config_file_value(section, key)


func write(section: String, key: String, value: Variant) -> void:
	SingletonObject.save_to_config_file(section, key, value)
