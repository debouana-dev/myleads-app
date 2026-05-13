import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_service.dart';

/// Thrown when the selected image exceeds the 5 MB upload limit.
class PhotoFileTooLargeException implements Exception {
  const PhotoFileTooLargeException();
}

/// Manages persistent photo storage for profile and contact images.
///
/// ## Path format
/// Stored paths are **relative** to the app's documents directory so they are
/// the same on every platform (Android, iOS).  The relative portion is:
///
///   profile_pictures/<userId>/<random10chars>.jpg
///   contact_pictures/<userId>/<random10chars>.jpg
///
/// Locally, files live at `<docsDir>/.images/<relativePath>`.
/// On the FTP server, files are stored at `photos/<relativePath>`.
///
/// ## Backward compatibility
/// Old records may carry an absolute path (starts with `/`).
/// [resolveAbsolutePath] detects these and returns them unchanged so existing
/// photos continue to display on the same device.  They are migrated to
/// relative paths the next time the user runs a full sync push.
class PhotoStorageService {
  PhotoStorageService._();

  static const int _maxBytes = 5 * 1024 * 1024; // 5 MB
  static const String _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// Cached absolute path to `getApplicationDocumentsDirectory()`.
  /// Populated once by [init]; must be called before any resolution.
  static String? _docsDir;

  // ── Initialisation ───────────────────────────────────────────────────────

  /// Caches the platform documents directory.  Call once in
  /// [StorageService.init] before the app renders any photo widget.
  static Future<void> init() async {
    if (kIsWeb) return;
    final dir = await getApplicationDocumentsDirectory();
    _docsDir = dir.path;
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Copies [sourcePath] into `.images/profile_pictures/<userId>/`.
  ///
  /// Returns the **relative** path on success, or null on failure.
  /// Throws [PhotoFileTooLargeException] if the file exceeds 5 MB.
  /// No-op on web (returns null).
  static Future<String?> saveProfilePhoto(String sourcePath) async {
    if (kIsWeb) return null;
    return _copyToDir(sourcePath, 'profile_pictures');
  }

  /// Copies [sourcePath] into `.images/contact_pictures/<userId>/`.
  ///
  /// Returns the **relative** path on success, or null on failure.
  /// Throws [PhotoFileTooLargeException] if the file exceeds 5 MB.
  /// No-op on web (returns null).
  static Future<String?> saveContactPhoto(String sourcePath) async {
    if (kIsWeb) return null;
    return _copyToDir(sourcePath, 'contact_pictures');
  }

  /// Resolves a stored path (relative or legacy absolute) to an absolute
  /// filesystem path suitable for use with [File] / [FileImage].
  ///
  /// - Returns null when [path] is null or empty.
  /// - Returns [path] unchanged if it is already absolute (legacy records).
  /// - Prepends `<docsDir>/.images/` for new relative paths.
  static String? resolveAbsolutePath(String? path) {
    if (path == null || path.isEmpty) return null;
    // Legacy absolute path — leave untouched for backward compat.
    if (path.startsWith('/') || path.contains(':\\')) return path;
    final dir = _docsDir;
    if (dir == null) return null;
    return p.join(dir, '.images', path);
  }

  /// Returns the local [File] for a relative [path], or null when the path
  /// cannot be resolved (e.g. before [init] was called or on web).
  static File? localFileForRelativePath(String? path) {
    final resolved = resolveAbsolutePath(path);
    return resolved != null ? File(resolved) : null;
  }

  /// Deletes the `.images/profile_pictures/<userId>` and
  /// `.images/contact_pictures/<userId>` directories from local storage.
  ///
  /// Errors are silently ignored. No-op on web or before [init] is called.
  static Future<void> deleteLocalUserFolders(String userId) async {
    if (kIsWeb) return;
    final dir = _docsDir;
    if (dir == null) return;
    for (final subDir in ['profile_pictures', 'contact_pictures']) {
      try {
        final folder = Directory(p.join(dir, '.images', subDir, userId));
        if (await folder.exists()) await folder.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ── Internals ────────────────────────────────────────────────────────────

  static String get _ownerFolder {
    final userId = StorageService.currentUserId;
    return userId.isEmpty ? '_default' : userId;
  }

  static String _randomName() {
    final rng = Random.secure();
    return List.generate(10, (_) => _chars[rng.nextInt(_chars.length)]).join();
  }

  /// Copies [sourcePath] into `.images/<subDir>/<userId>/` and returns the
  /// **relative** path `<subDir>/<userId>/<filename>.jpg`.
  static Future<String?> _copyToDir(String sourcePath, String subDir) async {
    try {
      final source = File(sourcePath);
      final size = await source.length();
      if (size > _maxBytes) throw const PhotoFileTooLargeException();

      final appDir = await getApplicationDocumentsDirectory();
      // Cache the docs dir if not done yet (e.g. very early call).
      _docsDir ??= appDir.path;

      final owner = _ownerFolder;
      final relativePath = p.join(subDir, owner, '${_randomName()}.jpg');
      final targetFile = File(p.join(appDir.path, '.images', relativePath));

      if (!await targetFile.parent.exists()) {
        await targetFile.parent.create(recursive: true);
      }
      await source.copy(targetFile.path);
      return relativePath;
    } on PhotoFileTooLargeException {
      rethrow;
    } catch (_) {
      return null;
    }
  }
}
