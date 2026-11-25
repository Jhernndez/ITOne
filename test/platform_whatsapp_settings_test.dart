import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/platform_whatsapp_settings.dart';
import 'package:itone/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends PlatformWhatsAppRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  final calls = <(String, String?)>[];
  bool denied = false;
  @override
  Future<Map<String, dynamic>> call(String action, {String? tenantId}) async {
    calls.add((action, tenantId));
    if (denied) {
      throw const FunctionException(
        status: 403,
        details: {
          'error': 'Solo el propietario de Platform puede consultar el diagnóstico de Meta.',
        },
      );
    }
    return switch (action) {
      'configuration' => {
        'app_id': 'meta-app',
        'config_id': 'meta-config',
        'graph_version': 'v23.0',
        'webhook_url': 'https://example.test/webhook',
        'app_secret_configured': true,
        'webhook_verify_token_configured': false,
      },
      'tenants' => {
        'tenants': [
          {'id': 'first', 'name': 'Empresa Uno'},
          {'id': 'second', 'name': 'Empresa Dos'},
        ],
      },
      'diagnostics' => {
        'integration': tenantId == 'first'
            ? {
                'status': 'error',
                'business_account_id': 'old-waba',
                'phone_number_id': 'old-phone',
              }
            : null,
        'accounts': <Map<String, dynamic>>[],
      },
      'validate' => {
        'status': 'restricted',
        'message': 'Meta reporta restricciones.',
        'blocked_entities': ['BLOCKED'],
      },
      _ => throw StateError('Unexpected action'),
    };
  }
}

void main() {
  for (final role in ['platform_owner', 'platform_admin', 'platform_support']) {
    testWidgets('only platform owner sees Meta settings entry: $role', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(MaterialApp(home: PlatformWorkspacePage(role: role)));
      await t.pumpAndSettle();
      expect(
        find.text('WhatsApp y Meta'),
        role == 'platform_owner' ? findsOneWidget : findsNothing,
      );
      expect(t.takeException(), isNull);
    });
  }
  Future<void> open(WidgetTester t, _Repository repo) async {
    t.view.physicalSize = const Size(1100, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(home: PlatformWhatsAppSettings(repository: repo)),
    );
    await t.pumpAndSettle();
  }

  testWidgets(
    'shows global config separately from per-company diagnostic and validates selected company',
    (t) async {
      final repo = _Repository();
      await open(t, repo);
      expect(find.text('App ID: meta-app'), findsOneWidget);
      expect(find.text('App Secret: Configurado'), findsOneWidget);
      expect(find.text('WABA de la integración: old-waba'), findsOneWidget);
      await t.ensureVisible(find.text('Validar conexión con Meta'));
      await t.tap(find.text('Validar conexión con Meta'));
      await t.pumpAndSettle();
      expect(repo.calls, contains(('validate', 'first')));
      expect(
        find.text('Resultado: Meta reporta restricciones.'),
        findsOneWidget,
      );
      expect(find.text('blocked_entities: [BLOCKED]'), findsOneWidget);
      await t.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await t.tap(find.byType(DropdownButtonFormField<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('Empresa Dos').last);
      await t.pumpAndSettle();
      expect(repo.calls.last, ('diagnostics', 'second'));
      expect(find.textContaining('old-waba'), findsNothing);
      expect(find.textContaining('Resultado:'), findsNothing);
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Validar conexión con Meta'),
            )
            .onPressed,
        isNull,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('denied access displays explicit error without configuration', (
    t,
  ) async {
    final repo = _Repository()..denied = true;
    await open(t, repo);
    expect(find.textContaining('Solo el propietario'), findsOneWidget);
    expect(find.textContaining('App ID:'), findsNothing);
    expect(repo.calls.length, 1);
  });
}
