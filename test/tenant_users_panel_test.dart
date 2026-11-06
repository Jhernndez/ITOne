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
      canManageAccount: true,
    ),
  ];
  String? failure;
  String? savedTenant;
  int writes = 0;
  int creations = 0;
  String? createdEmail;
  String? createdPassword;
  int accountWrites = 0;
  String? accountPassword;

  @override
  Future<void> updateAccount(
    String tenantId,
    TenantUser user,
    String fullName,
    String? temporaryPassword,
  ) async {
    if (failure != null) {
      throw FunctionException(status: 409, details: {'error': failure});
    }
    savedTenant = tenantId;
    accountWrites++;
    accountPassword = temporaryPassword;
    users = users
        .map(
          (entry) => entry.id == user.id
              ? TenantUser(
                  id: entry.id,
                  email: entry.email,
                  name: fullName.trim(),
                  role: entry.role,
                  active: entry.active,
                  globallyDisabled: entry.globallyDisabled,
                  canManageAccount: entry.canManageAccount,
                )
              : entry,
        )
        .toList();
  }

  @override
  Future<void> create(
    String tenantId,
    String fullName,
    String email,
    TenantRole role,
    String temporaryPassword,
  ) async {
    if (failure != null) {
      throw FunctionException(status: 409, details: {'error': failure});
    }
    creations++;
    savedTenant = tenantId;
    createdEmail = email.trim().toLowerCase();
    createdPassword = temporaryPassword;
    users.add(
      TenantUser(
        id: 'new-user',
        email: createdEmail!,
        name: fullName.trim(),
        role: role,
        active: true,
        globallyDisabled: false,
      ),
    );
  }

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
  Future<void> openAccount(WidgetTester tester) async {
    await tester.ensureVisible(find.byTooltip('Editar Carlos Agente'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Editar Carlos Agente'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Nombre y contraseña'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'edits exclusive account name without changing password or role',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository);
      await openAccount(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nombre completo'),
        'Carlos Nuevo',
      );
      await tester.tap(find.text('Guardar cuenta'));
      await tester.pumpAndSettle();
      expect(repository.accountWrites, 1);
      expect(repository.accountPassword, isNull);
      expect(repository.savedTenant, 'company-one');
      expect(repository.users.last.role, TenantRole.agent);
      expect(repository.writes, 0);
      expect(find.text('Carlos Nuevo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('assigns a new temporal password and hides it after saving', (
    tester,
  ) async {
    final repository = _Repository();
    await _open(tester, repository);
    await openAccount(tester);
    final password = find.widgetWithText(
      TextFormField,
      'Nueva contraseña temporal (opcional)',
    );
    await tester.enterText(password, 'Short1');
    await tester.tap(find.text('Guardar cuenta'));
    await tester.pumpAndSettle();
    expect(repository.accountWrites, 0);
    await tester.enterText(password, 'Temporary-Changed123!');
    await tester.tap(find.text('Guardar cuenta'));
    await tester.pumpAndSettle();
    expect(repository.accountPassword, 'Temporary-Changed123!');
    expect(repository.accountWrites, 1);
    expect(find.text('Temporary-Changed123!'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disables account editing when backend marks a shared account', (
    tester,
  ) async {
    final repository = _Repository();
    repository.users[1] = const TenantUser(
      id: 'agent',
      name: 'Carlos Agente',
      email: 'agent@example.test',
      role: TenantRole.agent,
      active: true,
      globallyDisabled: false,
    );
    await _open(tester, repository);
    await tester.tap(find.byTooltip('Editar Carlos Agente'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Nombre y contraseña'),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.textContaining('se gestionan desde plataforma'),
      findsOneWidget,
    );
    expect(find.text('Guardar cambios'), findsOneWidget);
  });

  testWidgets('account failure is explicit and dialog fits mobile', (
    tester,
  ) async {
    final repository = _Repository()
      ..failure = 'Cuenta compartida. Gestiona desde plataforma.';
    await _open(tester, repository, mobile: true);
    await openAccount(tester);
    await tester.tap(find.text('Guardar cuenta'));
    await tester.pumpAndSettle();
    expect(
      find.text('Cuenta compartida. Gestiona desde plataforma.'),
      findsOneWidget,
    );
    expect(repository.accountWrites, 0);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('creates a new user in the current company with selected role', (
    tester,
  ) async {
    final repository = _Repository();
    await _open(tester, repository);
    await tester.tap(find.widgetWithText(FilledButton, 'Crear usuario'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre completo'),
      'Nueva Persona',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Correo electrónico'),
      ' NEW@EXAMPLE.TEST ',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Contraseña temporal'),
      'Temporary-Test123!',
    );
    await tester.tap(find.byType(DropdownButtonFormField<TenantRole>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supervisor').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Crear usuario').last);
    await tester.pumpAndSettle();
    expect(repository.creations, 1);
    expect(repository.savedTenant, 'company-one');
    expect(repository.createdEmail, 'new@example.test');
    expect(repository.createdPassword, 'Temporary-Test123!');
    expect(repository.users.last.role, TenantRole.supervisor);
    expect(find.text('Nueva Persona'), findsOneWidget);
    expect(
      find.text(
        'Usuario creado. Comparte la contraseña temporal de forma segura.',
      ),
      findsOneWidget,
    );
    expect(find.text('Temporary-Test123!'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'validates creation and keeps duplicate email errors in the dialog',
    (tester) async {
      final repository = _Repository()
        ..failure = 'Ese correo ya tiene una cuenta en ITONE.';
      await _open(tester, repository);
      await tester.tap(find.widgetWithText(FilledButton, 'Crear usuario'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Crear usuario').last);
      await tester.pumpAndSettle();
      expect(repository.creations, 0);
      expect(find.text('Ingresa el nombre.'), findsOneWidget);
      expect(find.text('Ingresa un correo válido.'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nombre completo'),
        'Persona Existente',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Correo electrónico'),
        'existing@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Contraseña temporal'),
        'Temporary-Test123!',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Crear usuario').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Ese correo ya tiene una cuenta en ITONE.'),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(repository.creations, 0);
      expect(repository.users.length, 2);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('creation dialog fits a mobile screen and defaults to Agente', (
    tester,
  ) async {
    await _open(tester, _Repository(), mobile: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Crear usuario'));
    await tester.pumpAndSettle();
    expect(find.text('Agente').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

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
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Agente').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ana Admin (tú)'), findsNothing);
    expect(find.text('Carlos Agente'), findsOneWidget);
    final statusField = find.descendant(
      of: find.byType(DropdownMenu<String>),
      matching: find.byType(TextField),
    );
    await tester.tap(statusField);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Activos').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No hay usuarios que coincidan con los filtros.'),
      findsOneWidget,
    );
    await tester.tap(statusField);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Inactivos').hitTestable(),
    );
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
