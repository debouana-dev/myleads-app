import 'dart:io' show SocketException;

import 'package:connectivity_plus/connectivity_plus.dart';
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

  // Security type discovered on the first successful connection.
  // Null means auto-detect (tries plain FTP then explicit FTPS).
  // Cached for the app session to avoid redundant failed attempts.
  static SecurityType? _cachedSecurityType;

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

  /// Deletes the entire `photos/<subDir>/<userId>/` folder from FTP.
  ///
  /// [subDir] is either `'profile_pictures'` or `'contact_pictures'`.
  /// Fire-and-forget: errors are silently ignored. No-op on web.
  static Future<void> deleteUserPhotoFolder(
      String subDir, String userId) async {
    if (kIsWeb) return;
    await _withConnection((ftp) async {
      try {
        if (!await _cd(ftp, _remoteRoot)) return false;
        if (!await _cd(ftp, subDir)) return true; // folder absent — nothing to do
        await ftp.deleteDirectory(userId);
        return true;
      } catch (_) {
        return true; // folder may not exist — treat as success
      }
    });
  }

  /// Verifies that the FTP server is reachable and the [_remoteRoot] directory
  /// can be accessed (or created).
  ///
  /// Returns `null` on success, `'no_connection'` when the device has no
  /// internet, or `'auth_failed'` for any FTP-level failure (wrong
  /// credentials, host unreachable, SSL mismatch, etc.).
  static Future<String?> testFtpConnection() async {
    if (kIsWeb) return 'unsupported_platform';
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return 'no_connection';
    final ok =
        await _withConnection((ftp) async => _mkcd(ftp, _remoteRoot));
    return ok ? null : 'auth_failed';
  }

  // ── Internals ────────────────────────────────────────────────────────────

  /// Auto-detecting connection wrapper.
  ///
  /// Tries plain FTP first; if that fails, retries with Explicit FTPS
  /// (SecurityType.FTPES — AUTH TLS on port 21), which OVH shared hosting
  /// and many other providers require.  The working type is cached for the
  /// rest of the app session so subsequent calls pay only one connection.
  static Future<bool> _withConnection(
      Future<bool> Function(FTPConnect ftp) action) async {
    if (_cachedSecurityType != null) {
      return _withConnectionOnce(action, _cachedSecurityType!);
    }
    for (final type in [SecurityType.ftp, SecurityType.ftpes]) {
      final ok = await _withConnectionOnce(action, type);
      if (ok) {
        _cachedSecurityType = type;
        debugPrint('FtpPhotoService: using $type (cached for this session)');
        return true;
      }
    }
    return false;
  }

  /// Opens a single connection with [securityType], runs [action], then
  /// disconnects.  Returns false on any failure; never throws.
  static Future<bool> _withConnectionOnce(
      Future<bool> Function(FTPConnect ftp) action,
      SecurityType securityType) async {
    final ftp = FTPConnect(
      AppConfig.ftpHost,
      port: AppConfig.ftpPort,
      user: AppConfig.ftpUsername,
      pass: AppConfig.ftpPassword,
      showLog: kDebugMode, // FTP protocol transcript visible in debug console
      timeout: 30,
      securityType: securityType,
    );
    try {
      final connected = await ftp.connect();
      if (!connected) return false;
      try {
        return await action(ftp);
      } catch (e) {
        debugPrint('FtpPhotoService action error [$securityType]: $e');
        return false;
      } finally {
        try {
          await ftp.disconnect();
        } catch (_) {}
      }
    } on SocketException catch (e) {
      debugPrint('FtpPhotoService socket error [$securityType]: $e');
      return false;
    } catch (e) {
      debugPrint('FtpPhotoService connect error [$securityType]: $e');
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
