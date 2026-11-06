class WhatsAppSignup {
  static bool get supported => false;

  static Future<void> prepare(String appId, String version) async {
    throw UnsupportedError('Conecta WhatsApp desde la versión web de ITONE.');
  }

  static Future<String> connect(String configId) async {
    throw UnsupportedError('Conecta WhatsApp desde la versión web de ITONE.');
  }
}
