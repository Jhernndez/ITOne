class BrowserNotifications {
  static bool get supported => false;

  static Future<bool> requestPermission() async => false;

  static void show({required String title, required String body}) {}
}
