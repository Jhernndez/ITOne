import 'dart:js_interop';

@JS('itoneWhatsAppPrepare')
external JSPromise<JSAny?> _prepare(JSString appId, JSString version);

@JS('itoneWhatsAppConnect')
external JSPromise<JSString> _connect(JSString configId);

class WhatsAppSignup {
  static bool get supported => true;

  static Future<void> prepare(String appId, String version) async {
    await _prepare(appId.toJS, version.toJS).toDart;
  }

  static Future<String> connect(String configId) async {
    return (await _connect(configId.toJS).toDart).toDart;
  }
}
