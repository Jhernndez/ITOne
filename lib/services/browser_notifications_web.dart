// The browser notification API is intentionally isolated to this web-only
// implementation; mobile builds use browser_notifications_stub.dart.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

class BrowserNotifications {
  static bool get supported => true;

  static Future<bool> requestPermission() async {
    final permission = await html.Notification.requestPermission();
    return permission == 'granted';
  }

  static void show({required String title, required String body}) {
    if (html.Notification.permission == 'granted') {
      html.Notification(title, body: body);
    }
  }
}
