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
  bool companiesFailed = false;
  Map<String, String>? saved;
  List<Map<String, dynamic>> accounts = [];
  @override
  Future<Map<String, dynamic>> saveConfiguration(
    Map<String, String> values,
  ) async {
    saved = Map.of(values);
    return {'ok': true, 'message': 'Configuración guardada.'};
  }

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
    if (action == 'tenants' && companiesFailed) {
      throw const FunctionException(
        status: 503,
        details: {'error': 'No se pudo listar las empresas.'},
      );
    }
    return switch (action) {
      'configuration' => {
        'app_id': '2169281667133692',
        'config_id': '3860984100732128',
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
        'accounts': tenantId == 'first' ? accounts : <Map<String, dynamic>>[],
      },
      'validate' => {
        'status': 'restricted',
        'message': 'Meta reporta restricciones.',
        'blocked_entities': ['BLOCKED'],
      },
      'check_app' => {
        'app_id': '2169281667133692',
        'app_name': 'ITONE',
        'app_credentials_valid': true,
        'webhook_matches': true,
        'webhook_active': true,
        'webhook_fields': ['messages'],
        'message': 'Esta prueba no registra números.',
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
      expect(find.text('App ID: 2169281667133692'), findsOneWidget);
      expect(find.text('App Secret: Configurado'), findsOneWidget);
      await t.ensureVisible(
        find.text('Identificadores técnicos de la integración'),
      );
      await t.tap(find.text('Identificadores técnicos de la integración'));
      await t.pumpAndSettle();
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
      expect(find.text('WhatsApp sin conectar'), findsOneWidget);
      expect(
        find.text('Identificadores técnicos de la integración'),
        findsNothing,
      );
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
  for (final mode in ['cloud_api', 'coexistence', 'unknown']) {
    testWidgets(
      'company account has honest connection mode and collapsible technical IDs: $mode',
      (t) async {
        final repo = _Repository()
          ..accounts = [
            {
              'id': 'account-one',
              'name': 'Canal de empresa',
              'display_phone_number': '+00 1234',
              'onboarding_mode': mode,
              'status': 'active',
              'business_account_id': 'account-waba',
              'phone_number_id': 'account-phone',
            },
          ];
        await open(t, repo);
        expect(
          find.text(switch (mode) {
            'cloud_api' =>
              'Conexión: Cloud API antigua · sin coexistencia acreditada',
            'coexistence' => 'Conexión: Coexistencia',
            _ => 'Conexión: Modalidad no confirmada',
          }),
          findsOneWidget,
        );
        expect(find.text('WABA: account-waba'), findsNothing);
        await t.ensureVisible(
          find.text('Identificadores técnicos de la cuenta'),
        );
        await t.tap(find.text('Identificadores técnicos de la cuenta'));
        await t.pumpAndSettle();
        expect(find.text('WABA: account-waba'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('denied access displays explicit error without configuration', (
    t,
  ) async {
    final repo = _Repository()..denied = true;
    await open(t, repo);
    expect(find.textContaining('Solo el propietario'), findsOneWidget);
    expect(find.textContaining('App ID:'), findsNothing);
    expect(repo.calls.length, 1);
  });

  testWidgets(
    'company load failure retains global config and allows independent app check',
    (t) async {
      final repo = _Repository()..companiesFailed = true;
      await open(t, repo);
      expect(find.text('App ID: 2169281667133692'), findsOneWidget);
      expect(
        find.textContaining('No se pudo listar las empresas'),
        findsOneWidget,
      );
      await t.tap(find.text('Comprobar aplicación de Meta'));
      await t.pumpAndSettle();
      expect(repo.calls.last, ('check_app', null));
      expect(find.text('Credenciales de aplicación: Válidas'), findsOneWidget);
      expect(find.text('Webhook de ITONE en Meta: Coincide'), findsOneWidget);
    },
  );

  testWidgets('owner edits IDs without exposing or replacing blank secrets', (
    t,
  ) async {
    final repo = _Repository();
    await open(t, repo);
    await t.tap(find.text('Editar configuración de Meta'));
    await t.pumpAndSettle();
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(4));
    expect(
      t.widget<TextFormField>(fields.at(0)).controller!.text,
      '2169281667133692',
    );
    expect(t.widget<TextFormField>(fields.at(2)).controller!.text, isEmpty);
    expect(t.widget<TextFormField>(fields.at(3)).controller!.text, isEmpty);
    final secretInput = t.widget<TextField>(
      find.descendant(of: fields.at(2), matching: find.byType(TextField)),
    );
    expect(secretInput.obscureText, isTrue);
    await t.enterText(fields.at(1), 'bad');
    await t.tap(find.text('Verificar y guardar'));
    await t.pumpAndSettle();
    expect(find.text('ID numérico obligatorio'), findsOneWidget);
    expect(repo.saved, isNull);
    await t.enterText(fields.at(1), '3860984100732128');
    await t.tap(find.text('Verificar y guardar'));
    await t.pumpAndSettle();
    expect(repo.saved, {
      'app_id': '2169281667133692',
      'config_id': '3860984100732128',
    });
    expect(find.text('Configuración guardada.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
