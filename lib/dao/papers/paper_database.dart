import 'dart:io';

import 'package:anx_reader/utils/get_path/databases_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema version of `paper_collection.db`.
const int paperDbVersion = 1;

const String paperDbFileName = 'paper_collection.db';

const _createSettingsSQL = '''
CREATE TABLE paper_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  daily_limit INTEGER NOT NULL DEFAULT 100,
  quota_day TEXT NOT NULL,
  reserved_count INTEGER NOT NULL DEFAULT 0,
  analysis_provider_id TEXT,
  analysis_model_override TEXT,
  poller_cursor TEXT,
  config_version INTEGER NOT NULL DEFAULT 1
)
''';

const _createTasksSQL = '''
CREATE TABLE paper_tasks (
  task_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  priority INTEGER NOT NULL DEFAULT 3,
  config_json TEXT NOT NULL,
  config_version INTEGER NOT NULL DEFAULT 1,
  query_revision INTEGER NOT NULL DEFAULT 1,
  create_time TEXT NOT NULL,
  modify_time TEXT NOT NULL,
  next_run_at TEXT
)
''';

const _createPapersSQL = '''
CREATE TABLE papers (
  arxiv_id TEXT PRIMARY KEY,
  latest_version INTEGER NOT NULL DEFAULT 1,
  title TEXT NOT NULL,
  authors_json TEXT NOT NULL,
  abstract TEXT NOT NULL,
  categories_json TEXT NOT NULL,
  published_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  abs_url TEXT,
  pdf_url TEXT,
  doi TEXT,
  journal_ref TEXT,
  content_hash TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  ignored INTEGER NOT NULL DEFAULT 0
)
''';

const _createMatchesSQL = '''
CREATE TABLE paper_task_matches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  query_revision INTEGER NOT NULL,
  arxiv_id TEXT NOT NULL,
  branch TEXT NOT NULL,
  evidence_json TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  rule_score INTEGER NOT NULL DEFAULT 0,
  ai_score INTEGER,
  analysis_cache_key TEXT,
  UNIQUE (task_id, query_revision, arxiv_id),
  FOREIGN KEY (task_id) REFERENCES paper_tasks(task_id),
  FOREIGN KEY (arxiv_id) REFERENCES papers(arxiv_id)
)
''';

const _createRunsSQL = '''
CREATE TABLE paper_runs (
  run_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  query_revision INTEGER NOT NULL,
  trigger TEXT NOT NULL,
  config_snapshot TEXT NOT NULL,
  range_json TEXT NOT NULL,
  status TEXT NOT NULL,
  phase_counts TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  failure_class TEXT,
  exec_token INTEGER NOT NULL DEFAULT 0
)
''';

const _createSlicesSQL = '''
CREATE TABLE paper_scan_slices (
  slice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  channel TEXT NOT NULL,
  branch_hash TEXT NOT NULL,
  from_utc TEXT NOT NULL,
  to_utc TEXT NOT NULL,
  request_query TEXT NOT NULL,
  start_index INTEGER NOT NULL DEFAULT 0,
  total_reported INTEGER,
  inserted_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  last_checked_at TEXT,
  failure_class TEXT,
  next_retry_at TEXT,
  source_limit INTEGER NOT NULL DEFAULT 0,
  UNIQUE (task_id, revision, channel, branch_hash, from_utc, to_utc)
)
''';

const _createAnalysesSQL = '''
CREATE TABLE paper_analyses (
  cache_key TEXT PRIMARY KEY,
  arxiv_id TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  model_fingerprint TEXT NOT NULL,
  prompt_version INTEGER NOT NULL,
  result_version INTEGER NOT NULL,
  title_zh TEXT,
  abstract_zh TEXT,
  assessments_json TEXT NOT NULL,
  status TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  quota_day TEXT,
  created_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  failure_class TEXT,
  next_retry_at TEXT,
  FOREIGN KEY (arxiv_id) REFERENCES papers(arxiv_id)
)
''';

const _createCitationsSQL = '''
CREATE TABLE paper_citations (
  arxiv_id TEXT PRIMARY KEY,
  provider TEXT NOT NULL DEFAULT 'semantic_scholar',
  provider_paper_id TEXT,
  citation_count INTEGER,
  last_success_at TEXT,
  last_attempt_at TEXT,
  last_error TEXT,
  next_refresh_at TEXT,
  FOREIGN KEY (arxiv_id) REFERENCES papers(arxiv_id)
)
''';

const _createImportsSQL = '''
CREATE TABLE paper_imports (
  arxiv_id TEXT PRIMARY KEY,
  download_version INTEGER NOT NULL,
  request_id TEXT NOT NULL,
  status TEXT NOT NULL,
  cache_rel_path TEXT,
  pdf_md5 TEXT,
  book_id INTEGER,
  book_file_path TEXT,
  attempt INTEGER NOT NULL DEFAULT 0,
  started_at TEXT,
  finished_at TEXT,
  failure_class TEXT,
  FOREIGN KEY (arxiv_id) REFERENCES papers(arxiv_id)
)
''';

const List<String> _createIndexSQL = <String>[
  'CREATE INDEX idx_papers_published ON papers(published_at, arxiv_id)',
  'CREATE INDEX idx_matches_task ON paper_task_matches(task_id, query_revision, arxiv_id)',
  'CREATE INDEX idx_slices_retry ON paper_scan_slices(status, next_retry_at)',
  'CREATE INDEX idx_citations_refresh ON paper_citations(next_refresh_at)',
  'CREATE INDEX idx_analyses_status ON paper_analyses(status, created_at)',
  'CREATE INDEX idx_imports_status ON paper_imports(status)',
];

/// Thrown when the on-disk paper database is newer than this build knows.
class PaperSchemaTooNewException implements Exception {
  PaperSchemaTooNewException(this.found, this.supported);
  final int found;
  final int supported;

  @override
  String toString() =>
      'paper_collection.db schema $found is newer than supported $supported';
}

/// Owns the `paper_collection.db` connection.
///
/// Deliberately independent of `DBHelper`/`BaseDao`, which are fixed to the
/// main library (`app_database.db`, version 7). The paper database is local
/// machine data and never enters the WebDAV full-library sync.
class PaperDatabase {
  PaperDatabase._();

  static final PaperDatabase instance = PaperDatabase._();

  Database? _db;
  bool inMaintenance = false;

  /// Test-only override for the database file path. Production code never
  /// sets this; it exists so integration tests can use isolated databases
  /// without touching user data.
  String? debugDbPathOverride;

  Future<Database> open() async {
    if (_db != null) return _db!;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final String path;
    final override = debugDbPathOverride;
    if (override != null) {
      path = override;
    } else {
      final dirPath = await getAnxDataBasesPath();
      await Directory(dirPath).create(recursive: true);
      path = p.join(dirPath, paperDbFileName);
    }

    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: paperDbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await _createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // v1 has no migrations yet; future upgrades must validate the
          // target file and take a recoverable snapshot first.
        },
        onDowngrade: (db, oldVersion, newVersion) async {
          // Never downgrade a newer database: disable the feature instead
          // of silently rebuilding or clearing it.
          throw PaperSchemaTooNewException(oldVersion, newVersion);
        },
        onOpen: (db) async {
          final rows = await db.rawQuery('PRAGMA user_version');
          final found = rows.isEmpty ? 0 : (rows.first.values.first as int);
          if (found > paperDbVersion) {
            throw PaperSchemaTooNewException(found, paperDbVersion);
          }
        },
      ),
    );
    _db = db;
    AnxLog.info('PaperDatabase: opened $path (schema $paperDbVersion)');
    return db;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute(_createSettingsSQL);
    await db.execute(_createTasksSQL);
    await db.execute(_createPapersSQL);
    await db.execute(_createMatchesSQL);
    await db.execute(_createRunsSQL);
    await db.execute(_createSlicesSQL);
    await db.execute(_createAnalysesSQL);
    await db.execute(_createCitationsSQL);
    await db.execute(_createImportsSQL);
    for (final sql in _createIndexSQL) {
      await db.execute(sql);
    }
    await db.insert('paper_settings', <String, Object?>{
      'id': 1,
      'daily_limit': 100,
      'quota_day': PaperQuotaDay.dayOf(DateTime.now().toUtc()),
      'reserved_count': 0,
      'config_version': paperDbVersion,
    });
  }

  Future<Database> get database {
    if (inMaintenance) {
      throw StateError('Paper storage is unavailable during maintenance');
    }
    return open();
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  Future<T> txn<T>(Future<T> Function(Transaction txn) action) async {
    final db = await database;
    return db.transaction(action);
  }
}

/// Small helper so quota-day formatting lives next to the schema without
/// importing the models file into the database layer.
class PaperQuotaDay {
  static String dayOf(DateTime utc) {
    final now = utc.toUtc();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
