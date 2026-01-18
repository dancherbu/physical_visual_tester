import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FileSystemIndexer {
  static Database? _db;
  static bool _isIndexing = false;

  /// Open or create the SQLite DB
  static Future<Database> get db async {
    if (_db != null) return _db!;
    
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docs.path, 'pvt_filesystem.db');
    
    // On Windows, load the dynamic library if needed (usually handled by sqlite3_flutter_libs mainly on mobile, 
    // strictly speaking on Desktop we might need `sqlite3.dll` alongside or use the proper loader.
    // 'sqlite3_flutter_libs' handles this for Android/iOS/macOS. 
    // Windows often needs `open.overrideFor(OperatingSystem.windows, ...)` if not bundled).
    // For now, we assume standard load works or user has sqlite3.dll in path.
    
    _db = sqlite3.open(dbPath);
    
    _layoutSchema(_db!);
    return _db!;
  }

  static void _layoutSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE,
        filename TEXT,
        extension TEXT,
        size_bytes INTEGER,
        modified_epoch INTEGER,
        parent_folder TEXT
      );
      
      CREATE INDEX IF NOT EXISTS idx_parent ON files(parent_folder);
      CREATE INDEX IF NOT EXISTS idx_ext ON files(extension);
      CREATE INDEX IF NOT EXISTS idx_mod ON files(modified_epoch);
    ''');
  }

  /// Start a background indexing of specific roots
  static Future<void> indexRoots(List<String> rootPaths) async {
    if (_isIndexing) return;
    _isIndexing = true;
    
    try {
      final database = await db;
      final stmt = database.prepare('''
        INSERT OR REPLACE INTO files (path, filename, extension, size_bytes, modified_epoch, parent_folder)
        VALUES (?, ?, ?, ?, ?, ?)
      ''');

      for (final root in rootPaths) {
         final dir = Directory(root);
         if (!dir.existsSync()) continue;
         
         // Non-recursive scan of top level first, then recursive? 
         // Let's do recursive but safe.
         // 'followLinks: false' to avoid loops.
         try {
             await for (final entity in dir.list(recursive: true, followLinks: false)) {
                 if (entity is File) {
                     try {
                        final stat = await entity.stat();
                        final path = entity.path;
                        final filename = p.basename(path);
                        final ext = p.extension(path).toLowerCase().replaceAll('.', '');
                        final parent = p.dirname(path);
                        
                        stmt.execute([
                           path,
                           filename,
                           ext,
                           stat.size,
                           stat.modified.millisecondsSinceEpoch,
                           parent
                        ]);
                     } catch (_) {}
                 }
             }
         } catch (e) {
             print('Error scanning $root: $e');
         }
      }
      stmt.dispose();
      print('✅ File System Indexing Complete.');
    } finally {
      _isIndexing = false;
    }
  }

  /// Query the index
  static Future<int> countFiles({String? where}) async {
      final database = await db;
      final query = where != null 
         ? 'SELECT COUNT(*) as c FROM files WHERE $where'
         : 'SELECT COUNT(*) as c FROM files';
      
      final result = database.select(query);
      return result.first['c'] as int;
  }
  
  static Future<List<Map<String, dynamic>>> runRawQuery(String sql) async {
      try {
          final database = await db;
          // Simple safety check: only SELECT allowed
          if (!sql.trim().toLowerCase().startsWith('select')) {
              return [{'error': 'Only SELECT queries allowed.'}];
          }
          final rs = database.select(sql);
          
          // Convert ResultSet to List<Map>
          final list = <Map<String, dynamic>>[];
          for (final row in rs) {
              final map = <String, dynamic>{};
              for (final col in rs.columnNames) {
                  map[col] = row[col];
              }
              list.add(map);
          }
          return list;
      } catch (e) {
          return [{'error': 'SQL Error: $e'}];
      }
  }
}
