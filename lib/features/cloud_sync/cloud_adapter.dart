import 'dart:typed_data';

abstract class CloudAdapter {
  Future<bool> isConnected();
  Future<void> ensureFolder(String path);
  Future<void> upload(String path, String data);
  Future<void> uploadBinary(String path, Uint8List data);
  Future<String> download(String path);
  Future<Uint8List> downloadBinary(String path);
  Future<void> deleteFile(String path);
  Future<void> deleteFolder(String path);
  Future<List<CloudFileInfo>> listFolder(String path);
  Future<Map<String, dynamic>?> getAccountInfo();
  Future<void> invalidateFolderCache();
}

class CloudFileNotFoundException implements Exception {
  final String path;

  const CloudFileNotFoundException(this.path);

  @override
  String toString() => 'Cloud file not found: $path';
}

class CloudFileInfo {
  final String path;
  final String name;
  final bool isFolder;

  const CloudFileInfo({
    required this.path,
    required this.name,
    required this.isFolder,
  });
}
