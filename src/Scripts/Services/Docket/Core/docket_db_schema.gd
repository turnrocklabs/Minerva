extends RefCounted
class_name DocketDBSchema
## Schema creation and migration for DocketDB.
## Extracted from DocketDB to keep schema DDL separate from CRUD logic.
## All methods take a DocketDB instance for SQL execution.


static func init_schema(db: DocketDB) -> void:
	db._exec("CREATE TABLE IF NOT EXISTS docket_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")

	db._exec("""CREATE TABLE IF NOT EXISTS items (
		id TEXT PRIMARY KEY,
		type TEXT NOT NULL, status TEXT NOT NULL,
		title TEXT NOT NULL DEFAULT '', description TEXT DEFAULT '',
		created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
		created_by TEXT DEFAULT '', assigned_to TEXT DEFAULT '',
		directed_to TEXT DEFAULT '',
		priority INTEGER DEFAULT 0, severity INTEGER DEFAULT 0,
		resolution TEXT, environment TEXT, repro_steps TEXT,
		assumed TEXT, corrected TEXT, findings TEXT, answer TEXT,
		occurred_at TEXT, detected_at TEXT, reported_at TEXT,
		why_chain TEXT, significant_events TEXT, contributing_factors TEXT,
		value TEXT, component TEXT, key TEXT,
		topic TEXT, subtopic TEXT, confidence TEXT,
		surprise TEXT, surfaced_from TEXT,
		retrieval_count INTEGER DEFAULT 0, research_cost INTEGER DEFAULT 0,
		blocked_by TEXT,
		parent TEXT DEFAULT '',
		test_setup TEXT, test_steps TEXT, expected_result TEXT,
		quality INTEGER DEFAULT 0, last_reviewed TEXT DEFAULT '',
		command TEXT, usage TEXT, prompt_text TEXT, preconditions TEXT,
		summary TEXT, article TEXT, parameters TEXT,
		steps TEXT, outcome TEXT
	);""")

	db._exec("""CREATE TABLE IF NOT EXISTS item_tags (
		item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
		tag TEXT NOT NULL, PRIMARY KEY (item_id, tag)
	);""")

	db._exec("""CREATE TABLE IF NOT EXISTS item_events (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
		event_type TEXT NOT NULL, actor TEXT DEFAULT '',
		timestamp TEXT NOT NULL, note TEXT DEFAULT ''
	);""")

	db._exec("""CREATE TABLE IF NOT EXISTS item_links (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		from_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
		to_id TEXT NOT NULL,
		relation TEXT NOT NULL
	);""")

	db._exec("""CREATE TABLE IF NOT EXISTS attachments (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
		filename TEXT NOT NULL,
		mime_type TEXT DEFAULT 'application/octet-stream',
		size_bytes INTEGER DEFAULT 0,
		data BLOB NOT NULL,
		created_at TEXT NOT NULL,
		description TEXT DEFAULT ''
	);""")

	db._exec("""CREATE TABLE IF NOT EXISTS comments (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
		parent_id INTEGER DEFAULT 0,
		author TEXT NOT NULL DEFAULT '',
		text TEXT NOT NULL DEFAULT '',
		status TEXT NOT NULL DEFAULT 'open',
		created_at TEXT NOT NULL,
		resolved_at TEXT DEFAULT '',
		resolved_by TEXT DEFAULT ''
	);""")

	db._exec("CREATE INDEX IF NOT EXISTS idx_comments_item ON comments(item_id);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_comments_status ON comments(status);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments(parent_id);")

	db._exec("CREATE TABLE IF NOT EXISTS saved_queries (name TEXT PRIMARY KEY, query_json TEXT NOT NULL);")

	db._exec("""CREATE TABLE IF NOT EXISTS docket_secrets (
		handle TEXT PRIMARY KEY,
		ciphertext BLOB NOT NULL,
		iv BLOB NOT NULL,
		mac BLOB NOT NULL,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL,
		requires_2fa INTEGER DEFAULT 0
	);""")

	db._exec("""CREATE TABLE IF NOT EXISTS docket_secret_versions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		handle TEXT NOT NULL,
		version INTEGER NOT NULL,
		ciphertext BLOB NOT NULL,
		iv BLOB NOT NULL,
		mac BLOB NOT NULL,
		created_at TEXT NOT NULL,
		rotated_by TEXT DEFAULT ''
	);""")
	db._exec("CREATE INDEX IF NOT EXISTS idx_secret_versions_handle ON docket_secret_versions(handle);")

	db._exec("""CREATE TABLE IF NOT EXISTS transition_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		timestamp TEXT NOT NULL,
		item_type TEXT NOT NULL,
		from_state TEXT NOT NULL,
		attempted_to TEXT NOT NULL,
		succeeded INTEGER NOT NULL DEFAULT 0,
		valid_transitions TEXT DEFAULT ''
	);""")
	db._exec("CREATE INDEX IF NOT EXISTS idx_transition_log_type ON transition_log(item_type);")

	db._exec("""CREATE TABLE IF NOT EXISTS mcp_error_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		timestamp TEXT NOT NULL,
		tool_name TEXT NOT NULL,
		error_message TEXT NOT NULL,
		arg_keys TEXT DEFAULT ''
	);""")
	db._exec("CREATE INDEX IF NOT EXISTS idx_mcp_error_tool ON mcp_error_log(tool_name);")

	# Indexes
	db._exec("CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_items_type_status ON items(type, status);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_items_component_key ON items(component, key);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_tags_tag ON item_tags(tag);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_events_item ON item_events(item_id);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_links_from ON item_links(from_id);")
	db._exec("CREATE INDEX IF NOT EXISTS idx_attachments_item ON attachments(item_id);")

	# Seed meta
	db._exec("INSERT OR IGNORE INTO docket_meta (key, value) VALUES ('version', '2.0.0');")
	db._exec("INSERT OR IGNORE INTO docket_meta (key, value) VALUES ('counter', '0');")
	db._exec("INSERT OR IGNORE INTO docket_meta (key, value) VALUES ('id_prefix', 'DKT');")

	migrate_schema(db)


static func migrate_schema(db: DocketDB) -> void:
	var col_rows := db._exec_select("PRAGMA table_info(items);")

	# Add missing TEXT columns
	for col_name in ["blocked_by", "findings",
			"test_setup", "test_steps", "expected_result", "last_reviewed",
			"command", "usage", "prompt_text", "preconditions",
			"summary", "article", "parameters",
			"steps", "outcome"]:
		if not DocketDB._has_column(col_rows, col_name):
			db._exec("ALTER TABLE items ADD COLUMN %s TEXT;" % col_name)

	# Columns with non-default defaults
	if not DocketDB._has_column(col_rows, "parent"):
		db._exec("ALTER TABLE items ADD COLUMN parent TEXT DEFAULT '';")
	if not DocketDB._has_column(col_rows, "quality"):
		db._exec("ALTER TABLE items ADD COLUMN quality INTEGER DEFAULT 0;")

	# Seed id_prefix if missing
	var prefix_rows := db._exec_select("SELECT value FROM docket_meta WHERE key='id_prefix';")
	if prefix_rows.is_empty():
		db._exec("INSERT OR IGNORE INTO docket_meta (key, value) VALUES ('id_prefix', 'DKT');")

	# Add comments table if missing
	var table_rows := db._exec_select("SELECT name FROM sqlite_master WHERE type='table' AND name='comments';")
	if table_rows.is_empty():
		db._exec("""CREATE TABLE IF NOT EXISTS comments (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
			parent_id INTEGER DEFAULT 0,
			author TEXT NOT NULL DEFAULT '',
			text TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'open',
			created_at TEXT NOT NULL,
			resolved_at TEXT DEFAULT '',
			resolved_by TEXT DEFAULT ''
		);""")
		db._exec("CREATE INDEX IF NOT EXISTS idx_comments_item ON comments(item_id);")
		db._exec("CREATE INDEX IF NOT EXISTS idx_comments_status ON comments(status);")
		db._exec("CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments(parent_id);")
	else:
		var ccols := db._exec_select("PRAGMA table_info(comments);")
		if not DocketDB._has_column(ccols, "parent_id"):
			db._exec("ALTER TABLE comments ADD COLUMN parent_id INTEGER DEFAULT 0;")
			db._exec("CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments(parent_id);")
		if not DocketDB._has_column(ccols, "resolved_at"):
			db._exec("ALTER TABLE comments ADD COLUMN resolved_at TEXT DEFAULT '';")
			db._exec("ALTER TABLE comments ADD COLUMN resolved_by TEXT DEFAULT '';")

	# Add docket_secrets table if missing
	var secrets_rows := db._exec_select("SELECT name FROM sqlite_master WHERE type='table' AND name='docket_secrets';")
	if secrets_rows.is_empty():
		db._exec("""CREATE TABLE IF NOT EXISTS docket_secrets (
			handle TEXT PRIMARY KEY,
			ciphertext BLOB NOT NULL,
			iv BLOB NOT NULL,
			mac BLOB NOT NULL,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			requires_2fa INTEGER DEFAULT 0
		);""")
	else:
		var scols := db._exec_select("PRAGMA table_info(docket_secrets);")
		if not DocketDB._has_column(scols, "requires_2fa"):
			db._exec("ALTER TABLE docket_secrets ADD COLUMN requires_2fa INTEGER DEFAULT 0;")

	# Add docket_secret_versions table if missing
	var vers_rows := db._exec_select("SELECT name FROM sqlite_master WHERE type='table' AND name='docket_secret_versions';")
	if vers_rows.is_empty():
		db._exec("""CREATE TABLE IF NOT EXISTS docket_secret_versions (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			handle TEXT NOT NULL,
			version INTEGER NOT NULL,
			ciphertext BLOB NOT NULL,
			iv BLOB NOT NULL,
			mac BLOB NOT NULL,
			created_at TEXT NOT NULL,
			rotated_by TEXT DEFAULT ''
		);""")
		db._exec("CREATE INDEX IF NOT EXISTS idx_secret_versions_handle ON docket_secret_versions(handle);")

	# Add transition_log table if missing
	var tlog_rows := db._exec_select("SELECT name FROM sqlite_master WHERE type='table' AND name='transition_log';")
	if tlog_rows.is_empty():
		db._exec("""CREATE TABLE IF NOT EXISTS transition_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			timestamp TEXT NOT NULL,
			item_type TEXT NOT NULL,
			from_state TEXT NOT NULL,
			attempted_to TEXT NOT NULL,
			succeeded INTEGER NOT NULL DEFAULT 0,
			valid_transitions TEXT DEFAULT ''
		);""")
		db._exec("CREATE INDEX IF NOT EXISTS idx_transition_log_type ON transition_log(item_type);")

	# Add mcp_error_log table if missing
	var elog_rows := db._exec_select("SELECT name FROM sqlite_master WHERE type='table' AND name='mcp_error_log';")
	if elog_rows.is_empty():
		db._exec("""CREATE TABLE IF NOT EXISTS mcp_error_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			timestamp TEXT NOT NULL,
			tool_name TEXT NOT NULL,
			error_message TEXT NOT NULL,
			arg_keys TEXT DEFAULT ''
		);""")
		db._exec("CREATE INDEX IF NOT EXISTS idx_mcp_error_tool ON mcp_error_log(tool_name);")

	# Relax FK on item_links.to_id to allow cross-project qualified refs
	var link_fk := db._exec_select("PRAGMA foreign_key_list(item_links);")
	var to_id_has_fk := false
	for fk in link_fk:
		if str(fk.get("from", "")) == "to_id":
			to_id_has_fk = true
			break
	if to_id_has_fk:
		db._exec("PRAGMA foreign_keys=OFF;")
		db._exec("BEGIN TRANSACTION;")
		db._exec("""CREATE TABLE item_links_new (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			from_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
			to_id TEXT NOT NULL,
			relation TEXT NOT NULL
		);""")
		db._exec("INSERT INTO item_links_new SELECT * FROM item_links;")
		db._exec("DROP TABLE item_links;")
		db._exec("ALTER TABLE item_links_new RENAME TO item_links;")
		db._exec("CREATE INDEX IF NOT EXISTS idx_links_from ON item_links(from_id);")
		db._exec("COMMIT;")
		db._exec("PRAGMA foreign_keys=ON;")
