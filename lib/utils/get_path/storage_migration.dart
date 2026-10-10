import 'dart:io';

import 'package:anx_reader/utils/log/common.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

void validateStoragePaths(String sourcePath, String destinationPath) {
  String resolved(String path) {
    final directory = Directory(path);
    if (directory.existsSync()) return directory.resolveSymbolicLinksSync();
    final parent = p.dirname(p.absolute(path));
    if (p.equals(parent, p.absolute(path))) {
      throw ArgumentError('Storage root does not exist');
    }
    return p.join(resolved(parent), p.basename(path));
  }

  final source = p.normalize(resolved(sourcePath));
  final target = p.normalize(resolved(destinationPath));
  if (p.equals(source, target) ||
      p.isWithin(source, target) ||
      p.isWithin(target, source)) {
    throw ArgumentError(
        'Storage locations must be distinct, non-nested directories');
  }
}

/// Compare the closed stores and book assets before publishing the new path.
Future<void> verifyStorageCopy(
    String sourcePath, String destinationPath) async {
  validateStoragePaths(sourcePath, destinationPath);
  for (final folder in ['file', 'cover', 'font', 'bgimg', 'databases']) {
    final source = Directory(p.join(sourcePath, folder));
    if (!source.existsSync()) continue;
    await for (final entry
        in source.list(recursive: true, followLinks: false)) {
      if (entry is Link) {
        throw StateError('Linked storage assets require manual migration');
      }
      if (entry is! File) continue;
      final target = File(p.join(
          destinationPath, folder, p.relative(entry.path, from: source.path)));
      if (!target.existsSync() ||
          await entry.length() != await target.length() ||
          await sha256.bind(entry.openRead()).first !=
              await sha256.bind(target.openRead()).first) {
        throw StateError(
            'Storage copy verification failed: ${p.relative(entry.path, from: sourcePath)}');
      }
    }
  }
}

/// Callback for migration progress updates
typedef MigrationProgressCallback = void Function(
    String currentItem, int progress, int total);

/// The owner holds the maintenance lock and keeps admission closed until this
/// returns. A failed rollback throws, so the owner must leave admission closed.
Future<bool> migrateStorageStores({
  required String sourcePath,
  required String destinationPath,
  required Future<void> Function() closeStores,
  required Future<void> Function(String path) publishPath,
  required Future<void> Function(String path) verifyStores,
  MigrationProgressCallback? onProgress,
}) async {
  validateStoragePaths(sourcePath, destinationPath);
  await closeStores();
  try {
    if (!await isDirectoryEmpty(destinationPath)) {
      throw StateError('Destination must be empty before migration');
    }
    if (!await performStorageMigration(
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        onProgress: onProgress)) {
      throw StateError('Storage copy failed');
    }
    await verifyStorageCopy(sourcePath, destinationPath);
    await publishPath(destinationPath);
    await verifyStores(destinationPath);
  } catch (error) {
    await closeStores();
    await publishPath(sourcePath);
    await verifyStores(sourcePath);
    AnxLog.severe('StorageMigration: source restored after failure: $error');
    return false;
  }
  await performStorageCleanup(
      sourcePath: sourcePath, destinationPath: destinationPath);
  return true;
}

/// Performs data migration from source path to destination path.
/// Used for custom storage location feature on Windows/macOS.
///
/// The copy and cleanup phases are separate: [performStorageMigration]
/// copies everything and returns true when the DESTINATION holds the
/// complete data — it does NOT delete the source. The caller must verify
/// the destination (databases open, files present) and publish the new
/// path BEFORE calling [performStorageCleanup]. A copy failure returns
/// false and leaves the source fully intact.
Future<bool> performStorageMigration({
  required String sourcePath,
  required String destinationPath,
  MigrationProgressCallback? onProgress,
}) async {
  validateStoragePaths(sourcePath, destinationPath);
  // Items to migrate: 5 folders + 1 log file = 6 items
  final dataFolders = ['file', 'cover', 'font', 'bgimg', 'databases'];
  const int totalItems = 6; // 5 folders + 1 log file

  try {
    if (!await isDirectoryEmpty(destinationPath)) {
      throw StateError('Destination must be empty before migration');
    }
    for (int i = 0; i < dataFolders.length; i++) {
      final folder = dataFolders[i];
      onProgress?.call(folder, i + 1, totalItems);

      final sourceDir =
          Directory('$sourcePath${Platform.pathSeparator}$folder');
      final destDir =
          Directory('$destinationPath${Platform.pathSeparator}$folder');

      if (!sourceDir.existsSync()) {
        continue;
      }

      if (!destDir.existsSync()) {
        await destDir.create(recursive: true);
      }

      await _copyDirectory(sourceDir, destDir);
      AnxLog.info('StorageMigration: Copied $folder successfully');
    }

    onProgress?.call('anx_reader.log', 6, totalItems);
    final sourceLogFile =
        File('$sourcePath${Platform.pathSeparator}anx_reader.log');
    if (sourceLogFile.existsSync()) {
      final destLogFile =
          File('$destinationPath${Platform.pathSeparator}anx_reader.log');
      await sourceLogFile.copy(destLogFile.path);
      AnxLog.info('StorageMigration: Copied log file successfully');
    }

    AnxLog.info('StorageMigration: copy complete (source kept)');
    return true;
  } catch (e) {
    AnxLog.severe('StorageMigration failed during copy: $e; source intact');
    return false;
  }
}

/// Removes the migrated data from the source path. Call ONLY after the
/// destination has been verified (databases open, files present) and the
/// runtime path has been published. Cleanup errors leave the source
/// partially present but never invalidate the verified destination.
Future<void> performStorageCleanup({
  required String sourcePath,
  required String destinationPath,
}) async {
  validateStoragePaths(sourcePath, destinationPath);
  final dataFolders = ['file', 'cover', 'font', 'bgimg', 'databases'];
  try {
    AnxLog.info(
        'StorageMigration: destination verified; cleaning up source data...');
    for (final folder in dataFolders) {
      final sourceDir =
          Directory('$sourcePath${Platform.pathSeparator}$folder');
      if (sourceDir.existsSync()) {
        await sourceDir.delete(recursive: true);
        AnxLog.info('StorageMigration: Deleted source $folder');
      }
    }
    final sourceLogFile =
        File('$sourcePath${Platform.pathSeparator}anx_reader.log');
    if (sourceLogFile.existsSync()) {
      await sourceLogFile.delete();
    }
    AnxLog.info('StorageMigration: source cleanup complete');
  } catch (e) {
    AnxLog.warning(
        'StorageMigration: cleanup phase failed after a verified copy: $e. '
        'Destination is authoritative; source may be partially deleted.');
  }
}

/// Checks if a directory is empty (contains no files or subdirectories)
Future<bool> isDirectoryEmpty(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    return true;
  }
  final contents = await dir.list().toList();
  return contents.isEmpty;
}

/// Gets the default storage path for Windows/macOS
Future<String> getDefaultStoragePath() async {
  return (await getApplicationSupportDirectory()).path;
}

/// Recursively copies a directory
Future<void> _copyDirectory(Directory source, Directory destination) async {
  await for (final entity
      in source.list(recursive: false, followLinks: false)) {
    if (entity is Link) {
      throw StateError('Linked storage assets require manual migration');
    }
    final newPath =
        '${destination.path}${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}';

    if (entity is File) {
      await entity.copy(newPath);
    } else if (entity is Directory) {
      final newDir = Directory(newPath);
      await newDir.create(recursive: true);
      await _copyDirectory(entity, newDir);
    }
  }
}
