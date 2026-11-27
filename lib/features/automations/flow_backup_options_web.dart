import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';

WebOptions backupWebOptions() =>
    // The current web picker otherwise preloads files up to 2 GB before our size check.
    // ignore: deprecated_member_use
    const FilePickerWebOptions(withData: false);
