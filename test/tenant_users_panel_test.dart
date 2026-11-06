import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/tenant_users/tenant_user.dart';
import 'package:itone/features/tenant_users/tenant_users_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends TenantUserRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  List<TenantUser> users = [
    const TenantUser(
      id: 'admin',
      email: 'admin@example.test',
      name: 'Ana Admin',
      role: TenantRole.administrator,
      active: true,
      globallyDisabled: false,
    ),
    const TenantUser(
      id: 'agent',
      email: 'agent@example.test',
      name: 'Carlos Agente',
      role: TenantRole.agent,
      active: true,
      globallyDisabled: false,
    ),
  ];
  String? failure;
  String? savedTenant;
  int writes = 0;

  @override
  String get currentUserId => 'admin';

  @override
  Future<List<TenantUser>> list(String tenantId) async => users.toList();

  @override
  Future<void> update(
    String tenantId,
    TenantUser user,
    TenantRole role,
    bool active,
  ) async {
    if (failure != null) throw PostgrestException(message: failure!);
    writes++;
    savedTenant = tenantId;
    users = users
        .map(
          (entry) => entry.id == user.id
              ? TenantUser(
                  id: entry.id,
                  email: entry.email,
                  name: entry.name,
                  role: role,
                  active: active,
                  globallyDisabled: entry.globallyDisabled,
                )
              : entry,
        )
        .toList();
  }
}

Future<void> _open(
  WidgetTester tester,
  _Repository repository, {
  bool mobile = false,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(390, 844)
      : const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(
          child: TenantUsersPanel(
            tenantId: 'company-one',
            tenantName: 'Empresa Uno',
            repository: repository,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'parses persisted roles and distinguishes tenant access from global bans',
    () {
      final user = TenantUser.fromJson({
        'user_id': 'user',
        'email': 'agent@example.test',
        'full_name': '',
        'role': 'operator',
        'is_active': true,
        'is_globally_disabled': true,
        'last_sign_in_at': '2026-11-06T12:00:00Z',
      });
      expect(user.role, TenantRole.agent);
      expect(user.role.label, 'Agente');
      expect(user.displayName, 'agent');
      expect(user.active, isTrue);
      expect(user.effectiveActive, isFalse);
      expect(user.lastSignIn, DateTime.utc(2026, 11, 6, 12));
      expect(() => TenantRole.parse('platform_owner'), throwsStateError);
    },
  );

  testWidgets('filters by fixed role and active membership status', (
    tester,
  ) async {
    final repository = _Repository();
    repository.users[1] = const TenantUser(
      id: 'agent',
      email: 'agent@example.test',
      name: 'Carlos Agente',
      role: TenantRole.agent,
      active: false,
      globallyDisabled: false,
    );
    await _open(tester, repository);
    final roleField = find.descendant(
      of: find.byType(DropdownMenu<TenantRole?>),
      matching: find.byType(TextField),
    );
    await tester.tap(roleField);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Agente').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Ana Admin (tú)'), findsNothing);
    expect(find.text('Carlos Agente'), findsOneWidget);
    final statusField = find.descendant(
      of: find.byType(DropdownMenu<String>),
      matching: find.byType(TextField),
    );
    await tester.tap(statusField);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Activos').hitTestable());
    await tester.pumpAndSettle();
    expect(
      find.text('No hay usuarios que coincidan con los filtros.'),
      findsOneWidget,
    );
    await tester.tap(statusField);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Inactivos').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Carlos Agente'), findsOneWidget);
  });

  testWidgets('loads real rows, searches users and protects own actions', (
    tester,
  ) async {
    await _open(tester, _Repository());
    expect(find.text('Ana Admin (tú)'), findsOneWidget);
    expect(find.text('Carlos Agente'), findsOneWidget);
    expect(find.text('Agregar Usuario'), findsNothing);
    final selfEdit = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('No puedes editar tu propio acceso'),
        matching: find.byType(IconButton),
      ),
    );
    expect(selfEdit.onPressed, isNull);
    final search = find.widgetWithText(
      TextField,
      'Buscar por nombre, correo o rol...',
    );
    await tester.enterText(search, 'carlos');
    await tester.pumpAndSettle();
    expect(find.text('Carlos Agente'), findsOneWidget);
    expect(find.text('Ana Admin (tú)'), findsNothing);
    expect(find.text('Mostrando 1–1 de 1 usuarios'), findsOneWidget);
    await tester.enterText(search, 'sin resultados');
    await tester.pumpAndSettle();
    expect(
      find.text('No hay usuarios que coincidan con los filtros.'),
      findsOneWidget,
    );
  });

  testWidgets('saves role and membership state for the selected tenant only', (
    tester,
  ) async {
    final repository = _Repository();
    await _open(tester, repository);
    await tester.tap(find.byTooltip('Editar Carlos Agente'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<TenantRole>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supervisor').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('Guardar cambios'));
    await tester.pumpAndSettle();
    expect(repository.writes, 1);
    expect(repository.savedTenant, 'company-one');
    expect(repository.users.last.role, TenantRole.supervisor);
    expect(repository.users.last.active, isFalse);
    expect(find.text('Inactivo'), findsOneWidget);
    expect(find.text('Acceso de Carlos Agente actualizado.'), findsOneWidget);
  });

  testWidgets(
    'requires confirmation and displays backend failures without success',
    (tester) async {
      final repository = _Repository()
        ..failure = 'Tu acceso cambió. Actualiza la lista.';
      await _open(tester, repository);
      await tester.tap(find.byTooltip('Más acciones de Carlos Agente'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desactivar acceso'));
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
      await tester.tap(find.text('Desactivar'));
      await tester.pumpAndSettle();
      expect(
        find.text('Tu acceso cambió. Actualiza la lista.'),
        findsOneWidget,
      );
      expect(repository.users.last.active, isTrue);
      expect(find.text('Acceso de Carlos Agente actualizado.'), findsNothing);
    },
  );

  testWidgets('roles and permissions are read-only and disclose demo modules', (
    tester,
  ) async {
    await _open(tester, _Repository());
    await tester.tap(find.widgetWithText(TextButton, 'Roles'));
    await tester.pumpAndSettle();
    expect(find.text('Roles fijos de la empresa'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Permisos'));
    await tester.pumpAndSettle();
    expect(find.text('Permisos por rol'), findsOneWidget);
    expect(find.textContaining('vistas de demostración'), findsOneWidget);
    expect(find.text('Crear rol'), findsNothing);
  });

  testWidgets('paginates without fabricated totals', (tester) async {
    final repository = _Repository();
    repository.users = List.generate(
      10,
      (index) => TenantUser(
        id: 'user-$index',
        email: 'user$index@example.test',
        name: 'Usuario $index',
        role: TenantRole.agent,
        active: true,
        globallyDisabled: false,
      ),
    );
    await _open(tester, repository);
    expect(find.text('Mostrando 1–8 de 10 usuarios'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Página siguiente'));
    await tester.tap(find.byTooltip('Página siguiente'));
    await tester.pumpAndSettle();
    expect(find.text('Mostrando 9–10 de 10 usuarios'), findsOneWidget);
    expect(find.text('Usuario 9'), findsOneWidget);
  });

  testWidgets('fits mobile width with a horizontally scrollable table', (
    tester,
  ) async {
    await _open(tester, _Repository(), mobile: true);
    expect(find.text('Resumen de permisos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
