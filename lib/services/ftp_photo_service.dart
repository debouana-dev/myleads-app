import 'package:flutter/foundation.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import 'photo_storage_service.dart';

/// Handles FTP upload, download, and deletion of photo files during sync.
///
/// Remote paths always sit beneath the [_remoteRoot] folder on the server:
///   photos/profile_pictures/<userId>/<filename>.jpg
///   photos/contact_pictures/<userId>/<filename>.jpg
///
/// The [relativePath] argument matches the value stored in the database, e.g.
///   profile_pictures/<userId>/<filename>.jpg
///
/// All errors are swallowed so FTP failures never break the DB sync flow.
class FtpPhotoService {
  FtpPhotoService._();

  static const String _remoteRoot = 'photos';

  // ── Public API ──────────────────────────────────────────────────────────

  /// Uploads the local file for [relativePath] to FTP.
  /// Returns true on success, false on any failure.  No-op on web.
  static Future<bool> uploadPhoto(String relativePath) async {
    if (kIsWeb) return false;
    final localFile =
        PhotoStorageService.localFileForRelativePath(relativePath);
    if (localFile == null || !await localFile.exists()) return false;

    return _withConnection((ftp) async {
      if (!await _mkcd(ftp, _remoteRoot)) return false;
      final dirPart = p.dirname(relativePath);
      for (final part in p.split(dirPart)) {
        if (part == '.' || part.isEmpty) continue;
        if (!await _mkcd(ftp, part)) return false;
      }
      return ftp.uploadFile(localFile, sRemoteName: p.basename(relativePath));
    });
  }

  /// Downloads the photo at [relativePath] from FTP to the local .images dir.
  /// Returns true on success, false on any failure (missing file, network …).
  /// No-op on web.
  static Future<bool> downloadPhoto(String relativePath) async {
    if (kIsWeb) return false;
    final localFile =
        PhotoStorageService.localFileForRelativePath(relativePath);
    if (localFile == null) return false;
    if (await localFile.exists()) return true; // already present

    return _withConnection((ftp) async {
      if (!await _cd(ftp, _remoteRoot)) return false;
      final dirPart = p.dirname(relativePath);
      for (final part in p.split(dirPart)) {
        if (part == '.' || part.isEmpty) continue;
        if (!await _cd(ftp, part)) return false;
      }
      await localFile.parent.create(recursive: true);
      return ftp.downloadFile(p.basename(relativePath), localFile);
    });
  }

  /// Deletes the photo at [relativePath] from FTP.
  /// Fire-and-forget: errors are silently ignored.  No-op on web.
  static Future<void> deletePhoto(String relativePath) async {
    if (kIsWeb) return;
    await _withConnection((ftp) async {
      if (!await _cd(ftp, _remoteRoot)) return false;
      final dirPart = p.dirname(relativePath);
      for (final part in p.split(dirPart)) {
        if (part == '.' || part.isEmpty) continue;
        if (!await _cd(ftp, part)) return false;
      }
      try {
        return await ftp.deleteFile(p.basename(relativePath));
      } catch (_) {
        return false;
      }
    });
  }

  // ── Internals ────────────────────────────────────────────────────────────

  /// Opens a connection, runs [action], then disconnects.
  /// Returns false on connection failure; swallows all action errors.
  static Future<bool> _withConnection(
      Future<bool> Function(FTPConnect ftp) action) async {
    final ftp = FTPConnect(
      AppConfig.ftpHost,
      port: AppConfig.ftpPort,
      user: AppConfig.ftpUsername,
      pass: AppConfig.ftpPassword,
      showLog: false,
      timeout: 90000, // 90s is a reasonable upper bound for mobile FTP ops
    );
    try {
      final connected = await ftp.connect();
      if (!connected) return false;
      try {
        return await action(ftp);
      } catch (e) {
        debugPrint('FtpPhotoService error: $e');
        return false;
      } finally {
        try {
          await ftp.disconnect();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('FtpPhotoService connect error: $e');
      return false;
    }
  }

  /// Creates [dir] on the server if it does not exist, then navigates into it.
  static Future<bool> _mkcd(FTPConnect ftp, String dir) async {
    try {
      await ftp.makeDirectory(dir);
    } catch (_) {
      // Directory already exists — ignore.
    }
    return _cd(ftp, dir);
  }

  /// Navigates into [dir]; returns false when the directory does not exist.
  static Future<bool> _cd(FTPConnect ftp, String dir) async {
    try {
      return await ftp.changeDirectory(dir);
    } catch (_) {
      return false;
    }
  }
}
