# Sourced helper: point Minerva at a fresh, throwaway user profile.
#
#   source scripts/lib/test-profile.sh
#   seed_test_profile "$(mktemp -d)"
#
# Exports XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME under <root> and
# seeds the Minerva user dir with voice and HCP auto-connect off and the known
# MCP servers disabled. Known servers otherwise default to auto-connect and can
# consume the shared schema helper's bounded admission slots mid-test.
seed_test_profile() {
	local root="$1" user_dir
	export XDG_CONFIG_HOME="$root/config"
	export XDG_DATA_HOME="$root/data"
	export XDG_CACHE_HOME="$root/cache"
	user_dir="$XDG_DATA_HOME/godot/app_userdata/Minerva"
	mkdir -p "$user_dir" || return 1
	cat > "$user_dir/config_file.cfg" <<'EOF' || return 1
[Voice]
turnrock_enabled=false
always_listening=false

[HCP]
auto_connect=false
EOF
	cat > "$user_dir/mcp_config.json" <<'EOF' || return 1
{"version":3,"servers":[{"name":"nudge","type":"http","url":"http://127.0.0.1:9","enabled":false,"auto_connect":false,"origin":"known"},{"name":"cobrowser","type":"http","url":"http://127.0.0.1:9","enabled":false,"auto_connect":false,"origin":"known"}]}
EOF
}
