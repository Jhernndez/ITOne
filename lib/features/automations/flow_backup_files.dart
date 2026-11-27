import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'flow_backup_options.dart'
    if (dart.library.js_interop) 'flow_backup_options_web.dart';

class FlowBackupFiles {
  Future<bool> save(Map<String, dynamic> backup) async {
    final result = await FilePicker.saveFile(
      fileName: 'itone-flujo-respaldo.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(backup))),
      mimeType: 'application/json',
    );
    return kIsWeb || result != null;
  }

  Future<Map<String, dynamic>?> open() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
      webOptions: backupWebOptions(),
    );
    if (file == null) return null;
    final length = file.lengthSync();
    if (length != null && length > 20000000) {
      throw const FormatException('El respaldo supera 20 MB.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > 20000000) {
        throw const FormatException('El respaldo supera 20 MB.');
      }
      bytes.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('El archivo no contiene un respaldo válido.');
    }
    return decoded;
  }
}
