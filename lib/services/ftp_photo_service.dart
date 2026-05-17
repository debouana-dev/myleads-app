import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import 'photo_storage_service.dart';

/// Handles SFTP upload, download, and deletion of photo files during sync.
///
/// Remote paths always sit beneath the [_remoteRoot] folder on the server:
///   photos/profile_pictures/<userId>/<filename>.jpg
///   photos/contact_pictures/<userId>/<filename>.jpg
///
/// The [relativePath] argument matches the value stored in the database, e.g.
///   profile_pictures/<userId>/<filename>.jpg
///
/// All errors are swallowed so SFTP failures never break the DB sync flow.
class FtpPhotoService {
  FtpPhotoService._();

  static const String _remoteRoot = 'photos';

  // ── Public API ──────────────────────────────────────────────────────────

  /// Uploads the local file for [relativePath] to the SFTP server.
  /// Returns true on success, false on any failure. No-op on web.
  static Future<bool> uploadPhoto(String relativePath) async {
    if (kIsWeb) return false;
    final localFile =
        PhotoStorageService.localFileForRelativePath(relativePath);
    if (localFile == null || !await localFile.exists()) return false;

    return _withSftp((sftp) async {
      final remote = '$_remoteRoot/$relativePath';
      await _mkdirp(sftp, p.dirname(remote));
      final remoteFile = await sftp.open(
        remote,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await remoteFile.write(localFile.openRead().cast<Uint8List>());
      } finally {
        await remoteFile.close();
      }
      return true;
    });
  }

  /// Downloads the photo at [relativePath] from the SFTP server to local storage.
  /// Returns true on success, false on any failure (missing file, network …).
  /// No-op on web.
  static Future<bool> downloadPhoto(String relativePath) async {
    if (kIsWeb) return false;
    final localFile =
        PhotoStorageService.localFileForRelativePath(relativePath);
    if (localFile == null) return false;
    if (await localFile.exists()) return true;

    return _withSftp((sftp) async {
      final remote = '$_remoteRoot/$relativePath';
      final remoteFile = await sftp.open(remote, mode: SftpFileOpenMode.read);
      try {
        await localFile.parent.create(recursive: true);
        final sink = localFile.openWrite();
        try {
          await for (final chunk in remoteFile.read()) {
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
      } finally {
        await remoteFile.close();
      }
      return true;
    });
  }

  /// Deletes the photo at [relativePath] from the SFTP server.
  /// Fire-and-forget: errors are silently ignored. No-op on web.
  static Future<void> deletePhoto(String relativePath) async {
    if (kIsWeb) return;
    await _withSftp((sftp) async {
      try {
        await sftp.remove('$_remoteRoot/$relativePath');
      } catch (_) {}
      return true;
    });
  }

  /// Deletes the entire `photos/<subDir>/<userId>/` folder from the SFTP server.
  ///
  /// [subDir] is either `'profile_pictures'` or `'contact_pictures'`.
  /// Fire-and-forget: errors are silently ignored. No-op on web.
  static Future<void> deleteUserPhotoFolder(
      String subDir, String userId) async {
    if (kIsWeb) return;
    await _withSftp((sftp) async {
      try {
        await _rmdirRecursive(sftp, '$_remoteRoot/$subDir/$userId');
      } catch (_) {}
      return true;
    });
  }

  /// Verifies that the SFTP server is reachable and the [_remoteRoot] directory
  /// can be accessed (or created).
  ///
  /// Returns `null` on success, `'no_connection'` when the device has no
  /// internet, or `'auth_failed'` for any SFTP-level failure (wrong
  /// credentials, host unreachable, etc.).
  static Future<String?> testFtpConnection() async {
    if (kIsWeb) return 'unsupported_platform';
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return 'no_connection';
    final ok = await _withSftp((sftp) async {
      await _mkdirp(sftp, _remoteRoot);
      return true;
    });
    return ok ? null : 'auth_failed';
  }

  // ── Internals ────────────────────────────────────────────────────────────

  /// Opens an authenticated SFTP session, runs [action], then closes the
  /// connection. Returns false on any error; never throws.
  static Future<bool> _withSftp(
      Future<bool> Function(SftpClient sftp) action) async {
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(
        AppConfig.ftpHost,
        AppConfig.ftpPort,
      ).timeout(const Duration(seconds: 30));
      client = SSHClient(
        socket,
        username: AppConfig.ftpUsername,
        onPasswordRequest: () => AppConfig.ftpPassword,
      );
      await client.authenticated.timeout(const Duration(seconds: 30));
      final sftp = await client.sftp();
      return await action(sftp);
    } catch (e) {
      debugPrint('FtpPhotoService SFTP error: $e');
      return false;
    } finally {
      client?.close();
    }
  }

  /// Creates every directory segment of [dirPath] on the server, ignoring
  /// errors for segments that already exist.
  static Future<void> _mkdirp(SftpClient sftp, String dirPath) async {
    String current = '';
    for (final part in p.split(dirPath)) {
      if (part == '.' || part.isEmpty) continue;
      current = current.isEmpty ? part : '$current/$part';
      try {
        await sftp.mkdir(current);
      } catch (_) {}
    }
  }

  /// Recursively deletes [path] on the server. Tries to remove each entry as
  /// a file first; on failure, recurses into it as a directory. Silently
  /// ignores all errors so a missing folder is treated as success.
  static Future<void> _rmdirRecursive(SftpClient sftp, String path) async {
    try {
      final entries = <SftpName>[];
      await for (final batch in sftp.readdir(path)) {
        entries.addAll(batch);
      }
      for (final item in entries) {
        if (item.filename == '.' || item.filename == '..') continue;
        final child = '$path/${item.filename}';
        try {
          await sftp.remove(child);
        } catch (_) {
          await _rmdirRecursive(sftp, child);
        }
      }
      await sftp.rmdir(path);
    } catch (_) {}
  }
}
