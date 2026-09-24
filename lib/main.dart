import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_supabaseUrl.isEmpty || _supabasePublishableKey.isEmpty) {
    runApp(const IToneApp(configurationError: true));
    return;
  }

  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabasePublishableKey,
  );
  runApp(const IToneApp());
}

class IToneApp extends StatelessWidget {
  const IToneApp({super.key, this.configurationError = false});

  final bool configurationError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ITONE',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5F6870),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: configurationError
          ? const ConfigurationErrorPage()
          : const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, snapshot) {
        if (auth.currentSession == null) {
          return const AuthPage();
        }
        return const TenantRouter();
      },
    );
  }
}

class TenantRouter extends StatelessWidget {
  const TenantRouter({super.key});

  Future<WorkspaceOptions> _workspaces() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser!;
    final disabled =
        await client.rpc('is_current_user_disabled') as bool? ?? false;
    if (disabled) {
      await client.auth.signOut();
      throw const AuthException(
        'Tu usuario está deshabilitado. Contacta al administrador.',
      );
    }
    final invitationId = user.userMetadata?['platform_invitation_id'];
    final invitationAccepted =
        user.userMetadata?['platform_invitation_accepted'] == true;

    if (invitationId is String &&
        invitationId.isNotEmpty &&
        !invitationAccepted) {
      await client.rpc(
        'accept_platform_invitation',
        params: {'p_invitation_id': invitationId},
      );
      await client.auth.updateUser(
        UserAttributes(
          data: {...?user.userMetadata, 'platform_invitation_accepted': true},
        ),
      );
    }

    final memberships = await client
        .from('tenant_memberships')
        .select('tenant_id, role, tenants(name, slug)')
        .eq('user_id', user.id);
    final platformMemberships = await client
        .from('platform_memberships')
        .select('role')
        .eq('user_id', user.id);
    return WorkspaceOptions(
      tenantMemberships: List<Map<String, dynamic>>.from(memberships),
      platformMembership: platformMemberships.isEmpty
          ? null
          : Map<String, dynamic>.from(platformMemberships.first),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    if (user?.userMetadata?['must_set_password'] == true) {
      return const PasswordSetupPage();
    }
    return FutureBuilder<WorkspaceOptions>(
      future: _workspaces(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return ErrorPage(
            message:
                'No fue posible cargar el espacio empresarial.\n${snapshot.error}',
            onRetry: () => (context as Element).markNeedsBuild(),
          );
        }
        final workspaces = snapshot.data!;
        if (workspaces.isEmpty) return const TenantOnboardingPage();
        if (workspaces.hasMultiple) {
          return WorkspaceSelector(workspaces: workspaces);
        }
        if (workspaces.platformMembership != null) {
          return PlatformWorkspacePage(
            role: workspaces.platformMembership!['role'] as String,
          );
        }
        return TenantWorkspacePage(
          membership: workspaces.tenantMemberships.first,
        );
      },
    );
  }
}

class WorkspaceOptions {
  const WorkspaceOptions({
    required this.tenantMemberships,
    required this.platformMembership,
  });

  final List<Map<String, dynamic>> tenantMemberships;
  final Map<String, dynamic>? platformMembership;

  bool get isEmpty => tenantMemberships.isEmpty && platformMembership == null;
  bool get hasMultiple =>
      platformMembership != null || tenantMemberships.length > 1;
}

class WorkspaceSelector extends StatelessWidget {
  const WorkspaceSelector({super.key, required this.workspaces});

  final WorkspaceOptions workspaces;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Selecciona un espacio'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(32),
            shrinkWrap: true,
            children: [
              Text(
                'Tus espacios de trabajo',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Elige si deseas administrar la plataforma o una empresa.',
              ),
              const SizedBox(height: 24),
              if (workspaces.platformMembership != null)
                _WorkspaceCard(
                  title: 'ITONE Platform',
                  subtitle:
                      'Administración global · Rol: ${workspaces.platformMembership!['role']}',
                  icon: Icons.admin_panel_settings,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlatformWorkspacePage(
                        role: workspaces.platformMembership!['role'] as String,
                      ),
                    ),
                  ),
                ),
              ...workspaces.tenantMemberships.map(
                (membership) => _WorkspaceCard(
                  title:
                      (membership['tenants'] as Map<String, dynamic>)['name']
                          as String,
                  subtitle:
                      'Identificador: ${(membership['tenants'] as Map<String, dynamic>)['slug']} · Rol: ${membership['role']}',
                  icon: Icons.business,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TenantWorkspacePage(membership: membership),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class PlatformWorkspacePage extends StatefulWidget {
  const PlatformWorkspacePage({super.key, required this.role});

  final String role;

  @override
  State<PlatformWorkspacePage> createState() => _PlatformWorkspacePageState();
}

class _PlatformWorkspacePageState extends State<PlatformWorkspacePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ITONE Platform'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Administración de plataforma',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text('Rol: ${widget.role}'),
                const SizedBox(height: 24),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.domain),
                    title: Text('Tenants y empresas'),
                    subtitle: Text(
                      'Aquí administraremos empresas, módulos, licencias e integraciones.',
                    ),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: Icon(Icons.security),
                    title: Text('Accesos de plataforma'),
                    subtitle: Text(
                      'Aquí concederemos permisos específicos a administradores e ingenieros.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PlatformInvitationsPage(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PlatformInvitationsPage(),
                    ),
                  ),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Invitar administrador o ingeniero'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlatformInvitationsPage extends StatefulWidget {
  const PlatformInvitationsPage({super.key});

  @override
  State<PlatformInvitationsPage> createState() =>
      _PlatformInvitationsPageState();
}

class _PlatformInvitationsPageState extends State<PlatformInvitationsPage> {
  final _emailController = TextEditingController();
  String? _platformRole;
  String? _tenantId;
  String _tenantRole = 'supervisor';
  List<Map<String, dynamic>> _tenants = [];
  List<Map<String, dynamic>> _accessUsers = [];
  final Set<String> _selectedUserIds = {};
  Map<String, dynamic>? _selectedUser;
  bool _loading = true;
  String? _error;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final client = Supabase.instance.client;
      final tenants = await client
          .from('tenants')
          .select('id, name, slug')
          .order('name');
      final accessUsers =
          await client.rpc('list_platform_access') as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _tenants = List<Map<String, dynamic>>.from(tenants);
        final grouped = <String, Map<String, dynamic>>{};
        for (final item in accessUsers) {
          final row = Map<String, dynamic>.from(item as Map);
          final userId = row['user_id'] as String;
          final user = grouped.putIfAbsent(
            userId,
            () => {...row, 'tenant_access': <Map<String, dynamic>>[]},
          );
          final tenantId = row['tenant_id'] as String?;
          if (tenantId != null) {
            (user['tenant_access'] as List<Map<String, dynamic>>).add({
              'tenant_id': tenantId,
              'tenant_name': row['tenant_name'],
              'tenant_role': row['tenant_role'],
            });
          }
        }
        _accessUsers = grouped.values.toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'No fue posible cargar las invitaciones.\n$error';
        _loading = false;
      });
    }
  }

  Future<void> _sendInvitation() async {
    final email = _emailController.text.trim().toLowerCase();
    if (!email.contains('@')) {
      setState(() => _error = 'Escribe un correo válido.');
      return;
    }
    setState(() {
      _error = null;
      _message = null;
    });
    try {
      await Supabase.instance.client.functions.invoke(
        'send-platform-invitation',
        body: {
          'email': email,
          'platform_role': _platformRole,
          'tenant_id': _tenantId,
          'tenant_role': _tenantId == null ? null : _tenantRole,
        },
      );
      _emailController.clear();
      if (mounted) {
        setState(() => _message = 'Invitación enviada correctamente.');
        await _loadData();
      }
    } on FunctionException catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No fue posible enviar la invitación.\n$error');
      }
    }
  }

  Future<void> _updateAccess({
    required String userId,
    required String? platformRole,
    required List<Map<String, String>> tenantAccess,
  }) async {
    try {
      await Supabase.instance.client.rpc(
        'update_platform_access_bulk',
        params: {
          'p_user_id': userId,
          'p_platform_role': platformRole,
          'p_tenant_access': tenantAccess,
        },
      );
      if (mounted) {
        setState(() => _message = 'Permisos actualizados.');
        await _loadData();
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<bool> _manageUserAction(String userId, String action) async {
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'manage-platform-user',
        body: {'user_id': userId, 'action': action},
      );
      if (response.data is Map && (response.data as Map)['ok'] != true) {
        throw Exception(
          (response.data as Map)['error'] ?? 'La operación falló.',
        );
      }
      if (mounted) {
        setState(
          () => _message = action == 'reset_password'
              ? 'Enlace de restablecimiento enviado.'
              : 'Acción ejecutada correctamente.',
        );
        await _loadData();
      }
      return true;
    } on FunctionException catch (error) {
      if (mounted) setState(() => _error = error.toString());
      return false;
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No fue posible ejecutar la acción.\n$error');
      }
      return false;
    }
  }

  Future<void> _removeTenantAccess(Map<String, dynamic> user) async {
    final tenantId = user['tenant_id'] as String?;
    if (tenantId == null) return;
    await Supabase.instance.client.rpc(
      'remove_user_from_tenant',
      params: {'p_user_id': user['user_id'], 'p_tenant_id': tenantId},
    );
    if (mounted) {
      setState(() => _message = 'Usuario eliminado del tenant.');
      await _loadData();
    }
  }

  Future<bool> _confirmUserAction(
    Map<String, dynamic> user,
    String action,
    String title,
    String message,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    if (action == 'remove_tenant') {
      await _removeTenantAccess(user);
      return true;
    }
    return await _manageUserAction(user['user_id'] as String, action);
  }

  void _selectUser(Map<String, dynamic> user, bool? selected) {
    final id = user['user_id'] as String;
    setState(() {
      if (selected == true) {
        _selectedUserIds.add(id);
        _selectedUser = user;
      } else {
        _selectedUserIds.remove(id);
        if (_selectedUser?['user_id'] == id) _selectedUser = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Invitaciones y accesos')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Usuarios activos',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _openUserPanel(),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Añadir usuario'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Selecciona un usuario para administrar su cuenta y permisos.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Colors.red)),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: Colors.green)),
            ],
            const SizedBox(height: 20),
            Expanded(
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: _accessUsers.isEmpty
                    ? const Center(
                        child: Text('No hay usuarios con accesos asignados.'),
                      )
                    : SingleChildScrollView(
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('')),
                            DataColumn(label: Text('Usuario')),
                            DataColumn(label: Text('Correo')),
                            DataColumn(label: Text('Acceso')),
                            DataColumn(label: Text('Tenant')),
                            DataColumn(label: Text('Rol')),
                          ],
                          rows: _accessUsers.map((user) {
                            final id = user['user_id'] as String;
                            return DataRow(
                              onSelectChanged: (_) => _openUserPanel(user),
                              cells: [
                                DataCell(
                                  Checkbox(
                                    value: _selectedUserIds.contains(id),
                                    onChanged: (value) =>
                                        _selectUser(user, value),
                                  ),
                                ),
                                DataCell(Text(id.substring(0, 8))),
                                DataCell(Text(user['email'] as String? ?? '')),
                                DataCell(
                                  Text(
                                    user['platform_role'] as String? ??
                                        'Tenant',
                                  ),
                                ),
                                DataCell(
                                  Text(
                                    ((user['tenant_access'] as List<dynamic>?)
                                                    ?.map(
                                                      (item) =>
                                                          (item
                                                              as Map)['tenant_name'],
                                                    )
                                                    .whereType<String>()
                                                    .join(', '))
                                                ?.isNotEmpty ==
                                            true
                                        ? (user['tenant_access']
                                                  as List<dynamic>)
                                              .map(
                                                (item) =>
                                                    (item
                                                        as Map)['tenant_name'],
                                              )
                                              .whereType<String>()
                                              .join(', ')
                                        : 'Sin tenant',
                                  ),
                                ),
                                DataCell(
                                  Text(
                                    ((user['tenant_access'] as List<dynamic>?)
                                                    ?.map(
                                                      (item) =>
                                                          (item
                                                              as Map)['tenant_role'],
                                                    )
                                                    .whereType<String>()
                                                    .join(', '))
                                                ?.isNotEmpty ==
                                            true
                                        ? (user['tenant_access']
                                                  as List<dynamic>)
                                              .map(
                                                (item) =>
                                                    (item
                                                        as Map)['tenant_role'],
                                              )
                                              .whereType<String>()
                                              .join(', ')
                                        : 'Sin rol',
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openUserPanel([Map<String, dynamic>? user]) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar panel',
      barrierColor: Colors.black54,
      pageBuilder: (context, animation, secondaryAnimation) => Align(
        alignment: Alignment.centerRight,
        child: _UserSidePanel(
          user: user,
          tenants: _tenants,
          onSavePermissions: _updateAccess,
          onInvite: (email, platformRole, tenantId, tenantRole) async {
            _emailController.text = email;
            _platformRole = platformRole;
            _tenantId = tenantId;
            _tenantRole = tenantRole;
            await _sendInvitation();
          },
          onAction: (action, title, message) => _confirmUserAction(
            user ?? <String, dynamic>{},
            action,
            title,
            message,
          ),
        ),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
      transitionDuration: const Duration(milliseconds: 220),
    );
  }
}

class _UserSidePanel extends StatefulWidget {
  const _UserSidePanel({
    required this.user,
    required this.tenants,
    required this.onSavePermissions,
    required this.onInvite,
    required this.onAction,
  });

  final Map<String, dynamic>? user;
  final List<Map<String, dynamic>> tenants;
  final Future<void> Function({
    required String userId,
    required String? platformRole,
    required List<Map<String, String>> tenantAccess,
  })
  onSavePermissions;
  final Future<void> Function(
    String email,
    String? platformRole,
    String? tenantId,
    String tenantRole,
  )
  onInvite;
  final Future<bool> Function(String action, String title, String message)
  onAction;

  @override
  State<_UserSidePanel> createState() => _UserSidePanelState();
}

class _UserSidePanelState extends State<_UserSidePanel> {
  int _tab = 0;
  final _emailController = TextEditingController();
  late bool _disabled = widget.user?['is_disabled'] as bool? ?? false;
  bool get _isNew => widget.user == null;

  @override
  void initState() {
    super.initState();
    final user = widget.user;
    _emailController.text = user?['email'] as String? ?? '';
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return Material(
      elevation: 16,
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: MediaQuery.sizeOf(context).width > 900 ? 560 : double.infinity,
        height: double.infinity,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  _isNew
                      ? 'Añadir usuario'
                      : user?['email'] as String? ?? 'Usuario',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (!_isNew) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 14, 28, 12),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      _PanelAction(
                        icon: Icons.key,
                        label: 'Restablecer contraseña',
                        onTap: () => widget.onAction(
                          'reset_password',
                          'Restablecer contraseña',
                          'Se enviará un enlace al correo del usuario.',
                        ),
                      ),
                      _PanelAction(
                        icon: _disabled ? Icons.check_circle : Icons.block,
                        label: _disabled
                            ? 'Activar usuario'
                            : 'Deshabilitar usuario',
                        onTap: () async {
                          final action = _disabled ? 'enable' : 'disable';
                          final completed = await widget.onAction(
                            action,
                            _disabled
                                ? 'Activar usuario'
                                : 'Deshabilitar usuario',
                            _disabled
                                ? 'El usuario podrá iniciar sesión nuevamente.'
                                : 'El usuario no podrá iniciar sesión.',
                          );
                          if (completed && mounted) {
                            setState(() => _disabled = !_disabled);
                          }
                        },
                      ),
                      _PanelAction(
                        icon: Icons.delete_outline,
                        label: 'Eliminar usuario',
                        onTap: () => widget.onAction(
                          'delete_user',
                          'Eliminar usuario',
                          'Esta acción elimina definitivamente la cuenta.',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Row(
                children: [
                  _PanelTab(
                    label: 'Detalles',
                    selected: _tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  _PanelTab(
                    label: 'Permisos',
                    selected: _tab == 1,
                    onTap: () => setState(() => _tab = 1),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(28),
                  children: [
                    if (_tab == 0) _detailsTab(user) else _permissionsTab(user),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailsTab(Map<String, dynamic>? user) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Información del usuario',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _emailController,
          readOnly: !_isNew,
          decoration: const InputDecoration(
            labelText: 'Correo electrónico',
            border: OutlineInputBorder(),
          ),
        ),
        if (!_isNew) ...[
          const SizedBox(height: 18),
          _InfoLine(
            label: 'Tenant actual',
            value: user?['tenant_name'] as String? ?? 'Sin tenant',
          ),
          _InfoLine(
            label: 'Rol actual',
            value: user?['tenant_role'] as String? ?? 'Sin rol',
          ),
        ],
      ],
    );
  }

  Widget _permissionsTab(Map<String, dynamic>? user) {
    return _AccessUserCard(
      access: user ?? <String, dynamic>{},
      tenants: widget.tenants,
      onSave: widget.onSavePermissions,
      onInvite: widget.onInvite,
      isNew: _isNew,
    );
  }
}

class _PanelAction extends StatelessWidget {
  const _PanelAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 20),
    label: Text(label),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    ),
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(value),
      ],
    ),
  );
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    ),
  );
}

class _AccessUserCard extends StatefulWidget {
  const _AccessUserCard({
    required this.access,
    required this.tenants,
    required this.onSave,
    required this.onInvite,
    required this.isNew,
  });

  final Map<String, dynamic> access;
  final List<Map<String, dynamic>> tenants;
  final Future<void> Function({
    required String userId,
    required String? platformRole,
    required List<Map<String, String>> tenantAccess,
  })
  onSave;
  final Future<void> Function(
    String email,
    String? platformRole,
    String? tenantId,
    String tenantRole,
  )
  onInvite;
  final bool isNew;

  @override
  State<_AccessUserCard> createState() => _AccessUserCardState();
}

class _AccessUserCardState extends State<_AccessUserCard> {
  final _newEmailController = TextEditingController();
  late String? _platformRole = widget.access['platform_role'] as String?;
  late final Map<String, String> _tenantRoles = {
    for (final item
        in (widget.access['tenant_access'] as List<dynamic>? ?? const []))
      (item as Map)['tenant_id'] as String:
          (item['tenant_role'] as String?) ?? 'supervisor',
  };
  bool _saving = false;

  @override
  void dispose() {
    _newEmailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.access['email'] as String? ?? 'Usuario';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.isNew) ...[
              TextField(
                controller: _newEmailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (!widget.isNew)
              Text(email, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _platformRole,
              decoration: const InputDecoration(
                labelText: 'Rol de plataforma',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Sin acceso a la plataforma'),
                ),
                DropdownMenuItem(
                  value: 'platform_admin',
                  child: Text('Administrador de plataforma'),
                ),
                DropdownMenuItem(
                  value: 'platform_support',
                  child: Text('Soporte de plataforma'),
                ),
              ],
              onChanged: (value) => setState(() => _platformRole = value),
            ),
            const SizedBox(height: 20),
            Text(
              'Tenants con permisos',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'Selecciona una o varias empresas. El usuario podrá elegir '
              'una de ellas al entrar a ITONE.',
            ),
            const SizedBox(height: 8),
            ...widget.tenants.map((tenant) {
              final tenantId = tenant['id'] as String;
              final selected = _tenantRoles.containsKey(tenantId);
              return CheckboxListTile(
                value: selected,
                contentPadding: EdgeInsets.zero,
                title: Text(tenant['name'] as String),
                subtitle: selected
                    ? DropdownButton<String>(
                        value: _tenantRoles[tenantId],
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                            value: 'tenant_admin',
                            child: Text('Administrador del tenant'),
                          ),
                          DropdownMenuItem(
                            value: 'supervisor',
                            child: Text('Supervisor'),
                          ),
                          DropdownMenuItem(
                            value: 'operator',
                            child: Text('Operador'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _tenantRoles[tenantId] = value);
                          }
                        },
                      )
                    : const Text('Sin acceso'),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    if (widget.isNew) _tenantRoles.clear();
                    _tenantRoles[tenantId] = 'supervisor';
                  } else {
                    _tenantRoles.remove(tenantId);
                  }
                }),
              );
            }),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving
                    ? null
                    : () async {
                        setState(() => _saving = true);
                        if (widget.isNew) {
                          await widget.onInvite(
                            _newEmailController.text.trim().toLowerCase(),
                            _platformRole,
                            _tenantRoles.isEmpty
                                ? null
                                : _tenantRoles.keys.first,
                            _tenantRoles.isEmpty
                                ? 'supervisor'
                                : _tenantRoles.values.first,
                          );
                        } else {
                          await widget.onSave(
                            userId: widget.access['user_id'] as String,
                            platformRole: _platformRole,
                            tenantAccess: _tenantRoles.entries
                                .map(
                                  (entry) => {
                                    'tenant_id': entry.key,
                                    'tenant_role': entry.value,
                                  },
                                )
                                .toList(),
                          );
                        }
                        if (mounted) setState(() => _saving = false);
                      },
                icon: const Icon(Icons.save),
                label: Text(_saving ? 'Guardando...' : 'Guardar permisos'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PasswordSetupPage extends StatefulWidget {
  const PasswordSetupPage({super.key});

  @override
  State<PasswordSetupPage> createState() => _PasswordSetupPageState();
}

class _PasswordSetupPageState extends State<PasswordSetupPage> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final password = _passwordController.text;
    if (password.length < 8) {
      setState(
        () => _error = 'La contraseña debe tener al menos 8 caracteres.',
      );
      return;
    }

    if (password != _confirmationController.text) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final user = Supabase.instance.client.auth.currentUser!;
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(
          password: password,
          data: {...?user.userMetadata, 'must_set_password': false},
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TenantRouter()),
      );
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible guardar la contraseña.\n$error',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FutureBuilder<Map<String, dynamic>?>(
                  future: Supabase.instance.client
                      .from('user_profiles')
                      .select('full_name')
                      .eq(
                        'user_id',
                        Supabase.instance.client.auth.currentUser?.id ?? '',
                      )
                      .maybeSingle()
                      .then(
                        (row) =>
                            row == null ? null : Map<String, dynamic>.from(row),
                      ),
                  builder: (context, snapshot) {
                    final email =
                        Supabase.instance.client.auth.currentUser?.email ?? '';
                    final name =
                        snapshot.data?['full_name'] as String? ??
                        email.split('@').first;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Bienvenido, ${name.isEmpty ? 'usuario' : name}',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    );
                  },
                ),
                Text(
                  'Configura tu contraseña',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Este es tu primer acceso a ITONE. Define una contraseña para continuar.',
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Nueva contraseña',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirmationController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmar contraseña',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: Colors.red[700])),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Guardando...' : 'Continuar'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isRegistration = true;
  bool _loading = false;
  String? _message;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (_isRegistration) {
        final response = await auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
        setState(() {
          _message = response.session == null
              ? 'Revisa tu correo para confirmar la cuenta. Después podrás iniciar sesión.'
              : 'Cuenta creada. Ahora configura tu empresa.';
        });
      } else {
        await auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible completar la operación.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isRegistration ? 'Crea tu empresa' : 'Ingresa a ITONE';
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'ITONE',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Correo electrónico',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => value != null && value.contains('@')
                        ? null
                        : 'Escribe un correo válido',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Contraseña',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => value != null && value.length >= 8
                        ? null
                        : 'Usa al menos 8 caracteres',
                  ),
                  const SizedBox(height: 24),
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: Colors.red[700])),
                  if (_message != null)
                    Text(_message!, style: TextStyle(color: Colors.green[700])),
                  if (_error != null || _message != null)
                    const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: Text(
                      _loading
                          ? 'Procesando...'
                          : _isRegistration
                          ? 'Crear cuenta'
                          : 'Iniciar sesión',
                    ),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() {
                            _isRegistration = !_isRegistration;
                            _error = null;
                            _message = null;
                          }),
                    child: Text(
                      _isRegistration
                          ? 'Ya tengo una cuenta'
                          : 'Crear una cuenta empresarial',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TenantOnboardingPage extends StatefulWidget {
  const TenantOnboardingPage({super.key});

  @override
  State<TenantOnboardingPage> createState() => _TenantOnboardingPageState();
}

class _TenantOnboardingPageState extends State<TenantOnboardingPage> {
  final _nameController = TextEditingController();
  final _slugController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _slugController.dispose();
    super.dispose();
  }

  Future<String> _tenantIdForSlug(String slug) async {
    final tenant = await Supabase.instance.client
        .from('tenants')
        .select('id')
        .eq('slug', slug)
        .single();
    return tenant['id'] as String;
  }

  Future<void> _createTenant() async {
    final name = _nameController.text.trim();
    final slug = _slugController.text.trim().toLowerCase();
    if (name.isEmpty || !RegExp(r'^[a-z0-9-]{3,40}$').hasMatch(slug)) {
      setState(
        () => _error = 'Indica el nombre y un identificador de 3 a 40 caracteres (a-z, 0-9 o -).',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc(
        'create_tenant_for_current_user',
        params: {'p_name': name, 'p_slug': slug},
      );
      if (mounted) {
        final tenantId = await _tenantIdForSlug(slug);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TenantWorkspacePage(
              membership: {'tenant_id': tenantId, 'role': 'tenant_admin'},
            ),
          ),
        );
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No fue posible crear la empresa.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración inicial'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Configura tu empresa',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Este será el espacio aislado donde gestionarás usuarios y operaciones.',
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la empresa',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _slugController,
                  decoration: const InputDecoration(
                    labelText: 'Identificador de empresa',
                    hintText: 'mi-empresa',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                if (_error != null)
                  Text(_error!, style: TextStyle(color: Colors.red[700])),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _loading ? null : _createTenant,
                  child: Text(_loading ? 'Creando...' : 'Crear empresa'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TenantWorkspacePage extends StatelessWidget {
  const TenantWorkspacePage({super.key, required this.membership});

  final Map<String, dynamic> membership;

  Future<Map<String, dynamic>> _tenant() async {
    return await Supabase.instance.client
        .from('tenants')
        .select(
          'id, name, slug, sector, logo_url, language, timezone, created_at',
        )
        .eq('id', membership['tenant_id'])
        .single();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _tenant(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return const ErrorPage(
            message: 'No fue posible cargar los datos de la empresa.',
          );
        }
        final tenant = snapshot.data!;
        return TenantOperationsShell(
          initialMembership: {...membership, 'tenants': tenant},
        );
      },
    );
  }
}

class TenantOperationsShell extends StatefulWidget {
  const TenantOperationsShell({super.key, required this.initialMembership});

  final Map<String, dynamic> initialMembership;

  @override
  State<TenantOperationsShell> createState() => _TenantOperationsShellState();
}

class _TenantOperationsShellState extends State<TenantOperationsShell> {
  late Map<String, dynamic> _activeMembership = widget.initialMembership;
  int _selectedIndex = 0;
  bool _sidebarCollapsed = false;
  String _presence = 'available';
  late final Future<List<Map<String, dynamic>>> _memberships =
      _loadMemberships();
  late final Future<Map<String, dynamic>?> _profile = _loadProfile();

  Future<Map<String, dynamic>?> _loadProfile() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;
    final row = await Supabase.instance.client
        .from('user_profiles')
        .select('full_name, avatar_url')
        .eq('user_id', user.id)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<List<Map<String, dynamic>>> _loadMemberships() async {
    final rows = await Supabase.instance.client
        .from('tenant_memberships')
        .select(
          'tenant_id, role, tenants(id, name, slug, sector, logo_url, language, timezone)',
        )
        .eq('user_id', Supabase.instance.client.auth.currentUser!.id);
    final memberships = List<Map<String, dynamic>>.from(
      rows.map((row) => Map<String, dynamic>.from(row)),
    );
    if (memberships.isEmpty) return [widget.initialMembership];
    return memberships;
  }

  String get _role => _activeMembership['role'] as String? ?? 'operator';

  List<_TenantModule> get _modules => [
    const _TenantModule('Dashboard', Icons.dashboard_outlined),
    const _TenantModule('Clientes', Icons.people_outline),
    const _TenantModule('WhatsApp Business', Icons.chat_outlined),
    const _TenantModule('Tickets', Icons.confirmation_number_outlined),
    const _TenantModule('Agenda', Icons.calendar_month_outlined),
    if (_role != 'operator')
      const _TenantModule('Reportes', Icons.bar_chart_outlined),
    if (_role == 'tenant_admin')
      const _TenantModule(
        'Usuarios y permisos',
        Icons.manage_accounts_outlined,
      ),
    if (_role == 'tenant_admin')
      const _TenantModule('Configuración', Icons.settings_outlined),
  ];

  void _changeTenant(Map<String, dynamic> membership) {
    setState(() {
      _activeMembership = membership;
      _selectedIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tenant = _activeMembership['tenants'] as Map<String, dynamic>;
    final modules = _modules;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Regresar',
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.arrow_back),
        ),
        title: Row(
          children: [
            if (_sidebarCollapsed) ...[
              _TenantBrand(tenant: tenant, height: 38),
              const SizedBox(width: 16),
            ],
            FutureBuilder<Map<String, dynamic>?>(
              future: _profile,
              builder: (context, snapshot) {
                final email =
                    Supabase.instance.client.auth.currentUser?.email ?? '';
                final name =
                    snapshot.data?['full_name'] as String? ??
                    email.split('@').first;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Bienvenido, ${name.isEmpty ? 'usuario' : name}',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      tenant['name'] as String,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Colors.black54),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        actions: [
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _memberships,
            builder: (context, snapshot) {
              final memberships = snapshot.data ?? const [];
              if (memberships.length < 2) return const SizedBox.shrink();
              return PopupMenuButton<String>(
                tooltip: 'Cambiar empresa',
                icon: const Icon(Icons.swap_horiz),
                onSelected: (tenantId) {
                  final selected = memberships.firstWhere(
                    (item) => item['tenant_id'] == tenantId,
                  );
                  _changeTenant(selected);
                },
                itemBuilder: (context) => memberships.map((item) {
                  final itemTenant = item['tenants'] as Map<String, dynamic>;
                  return PopupMenuItem(
                    value: item['tenant_id'] as String,
                    child: Text(itemTenant['name'] as String),
                  );
                }).toList(),
              );
            },
          ),
          FutureBuilder<Map<String, dynamic>?>(
            future: _profile,
            builder: (context, snapshot) => _UserPresenceMenu(
              profile: snapshot.data,
              role: _role,
              presence: _presence,
              onPresenceChanged: (presence) {
                setState(() => _presence = presence);
              },
              onLogout: () => Supabase.instance.client.auth.signOut(),
            ),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TenantSidebar(
            tenant: tenant,
            modules: modules,
            selectedIndex: _selectedIndex,
            role: _role,
            collapsed: _sidebarCollapsed,
            onToggle: () => setState(() {
              _sidebarCollapsed = !_sidebarCollapsed;
            }),
            onSelected: (index) => setState(() => _selectedIndex = index),
            onLogout: () => Supabase.instance.client.auth.signOut(),
          ),
          Expanded(
            child: _TenantModuleContent(
              module: modules[_selectedIndex],
              tenant: tenant,
              role: _role,
            ),
          ),
        ],
      ),
    );
  }
}

class _TenantSidebar extends StatelessWidget {
  const _TenantSidebar({
    required this.tenant,
    required this.modules,
    required this.selectedIndex,
    required this.role,
    required this.collapsed,
    required this.onToggle,
    required this.onSelected,
    required this.onLogout,
  });

  final Map<String, dynamic> tenant;
  final List<_TenantModule> modules;
  final int selectedIndex;
  final String role;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<int> onSelected;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: collapsed ? 76 : 248,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(collapsed ? 12 : 20, 20, 12, 18),
            child: collapsed
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Expandir menú',
                      onPressed: onToggle,
                      icon: const Icon(Icons.menu),
                    ),
                  )
                : Row(
                    children: [
                      IconButton(
                        tooltip: 'Contraer menú',
                        onPressed: onToggle,
                        icon: const Icon(Icons.menu),
                      ),
                      const SizedBox(width: 4),
                      _TenantBrand(tenant: tenant, height: 42),
                    ],
                  ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
              children: [
                if (!collapsed) _SidebarLabel(text: 'OPERACIONES'),
                for (var index = 0; index < modules.length; index++)
                  _SidebarItem(
                    module: modules[index],
                    selected: index == selectedIndex,
                    primary: primary,
                    collapsed: collapsed,
                    onTap: () => onSelected(index),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.logout_outlined, size: 20),
            title: collapsed ? null : const Text('Cerrar sesión'),
            onTap: onLogout,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: collapsed
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_roleLabel(role)} · ${tenant['slug']}',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: Colors.black45),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarLabel extends StatelessWidget {
  const _SidebarLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.1,
          color: Colors.black45,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.module,
    required this.selected,
    required this.primary,
    required this.collapsed,
    required this.onTap,
  });

  final _TenantModule module;
  final bool selected;
  final Color primary;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selected: selected,
        selectedTileColor: primary.withValues(alpha: 0.1),
        selectedColor: primary,
        leading: Icon(module.icon, size: 21),
        title: collapsed
            ? null
            : Text(
                module.label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
        contentPadding: EdgeInsets.symmetric(horizontal: collapsed ? 16 : 12),
        minLeadingWidth: collapsed ? 0 : null,
        horizontalTitleGap: collapsed ? 0 : 8,
        onTap: onTap,
      ),
    );
  }
}

class _TenantModule {
  const _TenantModule(this.label, this.icon);

  final String label;
  final IconData icon;
}

String _roleLabel(String role) {
  switch (role) {
    case 'tenant_admin':
      return 'Administrador';
    case 'supervisor':
      return 'Supervisor';
    default:
      return 'Operador';
  }
}

class _TenantModuleContent extends StatelessWidget {
  const _TenantModuleContent({
    required this.module,
    required this.tenant,
    required this.role,
  });

  final _TenantModule module;
  final Map<String, dynamic> tenant;
  final String role;

  @override
  Widget build(BuildContext context) {
    final isDashboard = module.label == 'Dashboard';
    final isWhatsApp = module.label == 'WhatsApp Business';
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.all(constraints.maxWidth > 900 ? 32 : 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  module.label,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  isDashboard
                      ? 'Resumen operativo de ${tenant['name']}.'
                      : 'Módulo preparado para ${tenant['name']}.',
                ),
                const SizedBox(height: 28),
                if (isDashboard && tenant['sector'] == 'ips')
                  role == 'operator'
                      ? const _IpsAgentDashboard()
                      : const _IpsDashboard()
                else if (isDashboard) ...[
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: const [
                      _MetricCard(
                        title: 'Clientes activos',
                        value: '0',
                        icon: Icons.people_outline,
                      ),
                      _MetricCard(
                        title: 'Chats pendientes',
                        value: '0',
                        icon: Icons.chat_outlined,
                      ),
                      _MetricCard(
                        title: 'Tickets abiertos',
                        value: '0',
                        icon: Icons.confirmation_number_outlined,
                      ),
                      _MetricCard(
                        title: 'Actividades de hoy',
                        value: '0',
                        icon: Icons.today_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
                if (isWhatsApp) const _WhatsAppBusinessInbox(),
                if (module.label == 'Configuración')
                  _TenantConfiguration(
                    tenant: tenant,
                    onSaved: (sector) {
                      tenant['sector'] = sector;
                    },
                    onLogoSaved: (logoUrl) {
                      tenant['logo_url'] = logoUrl;
                    },
                  ),
                if (!isDashboard &&
                    !isWhatsApp &&
                    module.label != 'Configuración')
                  Card(
                    child: ListTile(
                      leading: Icon(module.icon),
                      title: Text(
                        isDashboard
                            ? 'Bienvenido al centro de operaciones'
                            : isWhatsApp
                            ? 'Bandeja de WhatsApp Business'
                            : 'Este módulo estará disponible próximamente',
                      ),
                      subtitle: Text(
                        isDashboard
                            ? 'Rol actual: ${_roleLabel(role)}. Usa el menú lateral para navegar.'
                            : isWhatsApp
                            ? 'Administra tus conversaciones y contactos desde un solo lugar.'
                            : 'La estructura de permisos ya está preparada para este módulo.',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UserPresenceMenu extends StatelessWidget {
  const _UserPresenceMenu({
    required this.profile,
    required this.role,
    required this.presence,
    required this.onPresenceChanged,
    required this.onLogout,
  });

  final Map<String, dynamic>? profile;
  final String role;
  final String presence;
  final ValueChanged<String> onPresenceChanged;
  final VoidCallback onLogout;

  static const _presenceLabels = {
    'available': 'Disponible',
    'away': 'Ausente',
    'busy': 'Ocupado',
  };

  static const _presenceColors = {
    'available': Colors.green,
    'away': Colors.orange,
    'busy': Colors.red,
  };

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final name = (profile?['full_name'] as String?)?.trim().isNotEmpty == true
        ? profile!['full_name'] as String
        : user?.email?.split('@').first ?? 'Usuario';
    final avatarUrl = profile?['avatar_url'] as String?;
    final color = _presenceColors[presence] ?? Colors.green;
    return PopupMenuButton<String>(
      tooltip: 'Perfil y estado',
      onSelected: (value) {
        if (value == 'logout') {
          onLogout();
        } else if (_presenceLabels.containsKey(value)) {
          onPresenceChanged(value);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const PopupMenuDivider(),
        ..._presenceLabels.entries.map(
          (entry) => CheckedPopupMenuItem(
            value: entry.key,
            checked: entry.key == presence,
            child: Row(
              children: [
                _PresenceDot(color: _presenceColors[entry.key]!),
                const SizedBox(width: 8),
                Text(entry.value),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundImage: avatarUrl == null
                  ? null
                  : NetworkImage(avatarUrl),
              child: avatarUrl == null
                  ? Text(name.substring(0, 1).toUpperCase())
                  : null,
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, overflow: TextOverflow.ellipsis),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PresenceDot(color: color),
                      const SizedBox(width: 4),
                      Text(
                        _presenceLabels[presence] ?? 'Disponible',
                        style: TextStyle(fontSize: 12, color: color),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_down),
          ],
        ),
      ),
    );
  }
}

class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _IpsDashboard extends StatelessWidget {
  const _IpsDashboard();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth > 1100
                ? (constraints.maxWidth - 80) / 5
                : constraints.maxWidth > 700
                ? (constraints.maxWidth - 16) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _IpsMetricCard(
                  width: width,
                  title: 'Conversaciones activas',
                  value: '--',
                  change: 'Disponible cuando conectemos WhatsApp',
                  icon: Icons.chat,
                  color: Colors.green,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Manejadas por IA',
                  value: '--',
                  change: 'Disponible cuando configuremos IA',
                  icon: Icons.smart_toy_outlined,
                  color: Colors.blue,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Requieren intervención humana',
                  value: '--',
                  change: 'Disponible cuando existan conversaciones',
                  icon: Icons.person_outline,
                  color: Colors.orange,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Citas agendadas hoy',
                  value: '--',
                  change: 'Disponible cuando configuremos agenda',
                  icon: Icons.calendar_month,
                  color: Colors.deepPurple,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Tiempo promedio respuesta',
                  value: '--',
                  change: 'Disponible cuando existan atenciones',
                  icon: Icons.schedule,
                  color: Colors.teal,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _IpsAgentDashboard extends StatelessWidget {
  const _IpsAgentDashboard();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth > 700
                ? (constraints.maxWidth - 16) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _IpsMetricCard(
                  width: width,
                  title: 'Mis chats pendientes',
                  value: '--',
                  change: 'Disponible cuando conectemos WhatsApp',
                  icon: Icons.chat_outlined,
                  color: Colors.blue,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Citas de hoy',
                  value: '--',
                  change: 'Disponible cuando configuremos agenda',
                  icon: Icons.calendar_month,
                  color: Colors.deepPurple,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Tiempo de respuesta',
                  value: '--',
                  change: 'Aún sin datos',
                  icon: Icons.schedule,
                  color: Colors.teal,
                ),
                _IpsMetricCard(
                  width: width,
                  title: 'Atención humana',
                  value: '--',
                  change: 'Disponible cuando configuremos atención',
                  icon: Icons.person_outline,
                  color: Colors.green,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _IpsMetricCard extends StatelessWidget {
  const _IpsMetricCard({
    required this.width,
    required this.title,
    required this.value,
    required this.change,
    required this.icon,
    required this.color,
  });

  final double width;
  final String title;
  final String value;
  final String change;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    foregroundColor: color,
                    child: Icon(icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                change,
                style: TextStyle(
                  color: change.startsWith('-') ? Colors.red : Colors.green,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _tenantSectors = <String, String>{
  'general': 'Otro / General',
  'it_services': 'Servicios de TI',
  'msp': 'MSP / Soporte administrado',
  'ips': 'IPS / Salud',
  'therapy_center': 'Centro terapéutico',
  'consulting': 'Consultoría',
  'professional_services': 'Servicios profesionales',
  'logistics': 'Logística y transporte',
  'construction': 'Construcción',
  'education': 'Educación',
  'retail': 'Comercio y ventas',
  'manufacturing': 'Manufactura',
  'real_estate': 'Inmobiliaria',
  'nonprofit': 'Fundación / ONG',
};

class _TenantBrand extends StatelessWidget {
  const _TenantBrand({required this.tenant, this.height = 30});

  final Map<String, dynamic> tenant;
  final double height;

  @override
  Widget build(BuildContext context) {
    final logoUrl = tenant['logo_url'] as String?;
    final brand = logoUrl == null
        ? Text(tenant['name'] as String)
        : Image.network(
            logoUrl,
            height: height,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text(tenant['name'] as String),
          );
    return brand;
  }
}

class _TenantConfiguration extends StatefulWidget {
  const _TenantConfiguration({
    required this.tenant,
    required this.onSaved,
    required this.onLogoSaved,
  });

  final Map<String, dynamic> tenant;
  final ValueChanged<String> onSaved;
  final ValueChanged<String> onLogoSaved;

  @override
  State<_TenantConfiguration> createState() => _TenantConfigurationState();
}

class _TenantConfigurationState extends State<_TenantConfiguration> {
  final _nameController = TextEditingController();
  late String _sector = _tenantSectors.containsKey(widget.tenant['sector'])
      ? widget.tenant['sector'] as String
      : 'general';
  bool _saving = false;
  bool _uploading = false;
  bool _uploadingLogo = false;
  String? _avatarUrl;
  String? _message;
  late String _language = widget.tenant['language'] as String? ?? 'es';
  late String _timezone =
      widget.tenant['timezone'] as String? ?? 'America/Bogota';
  int _settingsTab = 0;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final row = await Supabase.instance.client
        .from('user_profiles')
        .select('full_name, avatar_url')
        .eq('user_id', user.id)
        .maybeSingle();
    if (mounted && row != null) {
      _nameController.text = row['full_name'] as String? ?? '';
      _avatarUrl = row['avatar_url'] as String?;
      setState(() {});
    }
  }

  Future<void> _saveProfile() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('user_profiles').upsert({
        'user_id': user.id,
        'full_name': _nameController.text.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      if (mounted) setState(() => _message = 'Información personal guardada.');
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final path = '${user.id}/avatar.${file.name.split('.').last}';
      await Supabase.instance.client.storage
          .from('user-avatars')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );
      final url = Supabase.instance.client.storage
          .from('user-avatars')
          .getPublicUrl(path);
      await Supabase.instance.client.from('user_profiles').upsert({
        'user_id': user.id,
        'avatar_url': url,
        'updated_at': DateTime.now().toIso8601String(),
      });
      if (mounted) {
        setState(() {
          _avatarUrl = '$url?updated=${DateTime.now().millisecondsSinceEpoch}';
          _message = 'Foto actualizada.';
        });
      }
    } on StorageException catch (error) {
      if (mounted) {
        setState(() => _message = 'Error de almacenamiento: ${error.message}');
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'No fue posible subir la foto. Revisa el bucket user-avatars.',
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickLogo() async {
    final tenantId = widget.tenant['id'] as String;
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() => _uploadingLogo = true);
    try {
      final bytes = await file.readAsBytes();
      final extension = file.name.split('.').last.toLowerCase();
      final path = '$tenantId/logo.$extension';
      await Supabase.instance.client.storage
          .from('tenant-logos')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );
      final url = Supabase.instance.client.storage
          .from('tenant-logos')
          .getPublicUrl(path);
      await Supabase.instance.client
          .from('tenants')
          .update({'logo_url': url})
          .eq('id', tenantId);
      widget.onLogoSaved(
        '$url?updated=${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) setState(() => _message = 'Logo actualizado.');
    } on StorageException catch (error) {
      if (mounted) {
        setState(() => _message = 'Error de almacenamiento: ${error.message}');
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = 'No fue posible subir el logo.');
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await Supabase.instance.client
          .from('tenants')
          .update({'sector': _sector})
          .eq('id', widget.tenant['id']);
      widget.onSaved(_sector);
      if (mounted) setState(() => _message = 'Sector guardado correctamente.');
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'No fue posible guardar el sector.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveRegional() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await Supabase.instance.client
          .from('tenants')
          .update({'language': _language, 'timezone': _timezone})
          .eq('id', widget.tenant['id']);
      widget.tenant['language'] = _language;
      widget.tenant['timezone'] = _timezone;
      if (mounted) {
        setState(() => _message = 'Preferencias regionales guardadas.');
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SizedBox(
        height: 500,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 220,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    for (final item in const [
                      ('General', 'Cuenta y empresa', Icons.tune),
                      ('Regional', 'Idioma y zona horaria', Icons.public),
                      (
                        'Integraciones',
                        'Conexiones externas',
                        Icons.hub_outlined,
                      ),
                      (
                        'WhatsApp',
                        'Bienvenida y automatizaciones',
                        Icons.chat_outlined,
                      ),
                    ])
                      ListTile(
                        selected:
                            _settingsTab ==
                            const [
                              ('General', 'Cuenta y empresa', Icons.tune),
                              (
                                'Regional',
                                'Idioma y zona horaria',
                                Icons.public,
                              ),
                              (
                                'Integraciones',
                                'Conexiones externas',
                                Icons.hub_outlined,
                              ),
                              (
                                'WhatsApp',
                                'Bienvenida y automatizaciones',
                                Icons.chat_outlined,
                              ),
                            ].indexOf(item),
                        leading: Icon(item.$3),
                        title: Text(item.$1),
                        subtitle: Text(item.$2),
                        onTap: () => setState(
                          () => _settingsTab = const [
                            ('General', 'Cuenta y empresa', Icons.tune),
                            ('Regional', 'Idioma y zona horaria', Icons.public),
                            (
                              'Integraciones',
                              'Conexiones externas',
                              Icons.hub_outlined,
                            ),
                            (
                              'WhatsApp',
                              'Bienvenida y automatizaciones',
                              Icons.chat_outlined,
                            ),
                          ].indexOf(item),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    if (_settingsTab == 0)
                      const TabBar(
                        tabs: [
                          Tab(text: 'Información personal'),
                          Tab(text: 'Información de la empresa'),
                        ],
                      ),
                    Expanded(
                      child: _settingsTab == 0
                          ? TabBarView(
                              children: [
                                _PersonalSettings(
                                  nameController: _nameController,
                                  avatarUrl: _avatarUrl,
                                  saving: _saving,
                                  uploading: _uploading,
                                  message: _message,
                                  onSave: _saveProfile,
                                  onPickAvatar: _pickAvatar,
                                ),
                                _CompanySettings(
                                  tenant: widget.tenant,
                                  sector: _sector,
                                  saving: _saving,
                                  uploadingLogo: _uploadingLogo,
                                  message: _message,
                                  onSectorChanged: (value) =>
                                      setState(() => _sector = value),
                                  onSave: _save,
                                  onPickLogo: _pickLogo,
                                ),
                              ],
                            )
                          : _settingsTab == 1
                          ? _RegionalSettings(
                              language: _language,
                              timezone: _timezone,
                              saving: _saving,
                              message: _message,
                              onLanguageChanged: (value) =>
                                  setState(() => _language = value),
                              onTimezoneChanged: (value) =>
                                  setState(() => _timezone = value),
                              onSave: _saveRegional,
                            )
                          : _settingsTab == 2
                          ? const _IntegrationsSettings()
                          : _WhatsAppSettings(
                              tenantId: widget.tenant['id'] as String,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionalSettings extends StatelessWidget {
  const _RegionalSettings({
    required this.language,
    required this.timezone,
    required this.saving,
    required this.message,
    required this.onLanguageChanged,
    required this.onTimezoneChanged,
    required this.onSave,
  });

  final String language;
  final String timezone;
  final bool saving;
  final String? message;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onTimezoneChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Preferencias regionales',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text('Configura el idioma y la zona horaria de tu empresa.'),
        const SizedBox(height: 24),
        DropdownButtonFormField<String>(
          initialValue: language,
          decoration: const InputDecoration(
            labelText: 'Idioma',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'es', child: Text('Español')),
            DropdownMenuItem(value: 'en', child: Text('English')),
          ],
          onChanged: saving
              ? null
              : (value) {
                  if (value != null) onLanguageChanged(value);
                },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: timezone,
          decoration: const InputDecoration(
            labelText: 'Zona horaria',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: 'America/Bogota',
              child: Text('Bogotá (GMT-5)'),
            ),
            DropdownMenuItem(
              value: 'America/Mexico_City',
              child: Text('Ciudad de México (GMT-6)'),
            ),
            DropdownMenuItem(
              value: 'America/New_York',
              child: Text('Nueva York (GMT-5/-4)'),
            ),
            DropdownMenuItem(
              value: 'Europe/Madrid',
              child: Text('Madrid (GMT+1/+2)'),
            ),
          ],
          onChanged: saving
              ? null
              : (value) {
                  if (value != null) onTimezoneChanged(value);
                },
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: saving ? null : onSave,
          icon: const Icon(Icons.save_outlined),
          label: Text(saving ? 'Guardando...' : 'Guardar preferencias'),
        ),
        if (message != null) ...[const SizedBox(height: 12), Text(message!)],
      ],
    );
  }
}

class _IntegrationsSettings extends StatelessWidget {
  const _IntegrationsSettings();

  @override
  Widget build(BuildContext context) {
    final integrations = [
      (
        'WhatsApp Business',
        'Mensajería y atención por WhatsApp Cloud API.',
        Icons.chat_outlined,
      ),
      (
        'Microsoft 365',
        'Calendarios, usuarios y servicios de Microsoft.',
        Icons.business_center_outlined,
      ),
      (
        'Google Workspace',
        'Calendario, contactos y servicios de Google.',
        Icons.public,
      ),
      (
        'API privada',
        'Conecta una plataforma propia mediante API y webhooks.',
        Icons.api_outlined,
      ),
    ];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Integraciones', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Conecta servicios externos de forma independiente para este tenant.',
        ),
        const SizedBox(height: 20),
        ...integrations.map(
          (integration) => Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(integration.$3),
              title: Text(integration.$1),
              subtitle: Text(integration.$2),
              trailing: const Chip(label: Text('No configurada')),
            ),
          ),
        ),
      ],
    );
  }
}

class _WhatsAppSettings extends StatelessWidget {
  const _WhatsAppSettings({required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'Integración'),
                Tab(text: 'Bienvenida'),
                Tab(text: 'Flujo de mensajes'),
                Tab(text: 'SLA'),
                Tab(text: 'Automatizaciones'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _WhatsAppIntegrationPanel(tenantId: tenantId),
                _WhatsAppSettingPanel(
                  icon: Icons.waving_hand_outlined,
                  title: 'Mensaje de bienvenida',
                  description: 'Define el mensaje inicial, el horario de atención y las opciones que verá el contacto al iniciar una conversación.',
                  actionLabel: 'Crear mensaje de bienvenida',
                ),
                _WhatsAppSettingPanel(
                  icon: Icons.account_tree_outlined,
                  title: 'Flujo de mensajes',
                  description: 'Diseña el recorrido de atención: menú inicial, respuestas, derivación a un agente y cierre de la conversación.',
                  actionLabel: 'Crear flujo',
                ),
                _WhatsAppSettingPanel(
                  icon: Icons.timer_outlined,
                  title: 'Acuerdos de nivel de servicio',
                  description: 'Configura tiempos objetivo de primera respuesta, atención y escalamiento según la prioridad del contacto.',
                  actionLabel: 'Configurar SLA',
                ),
                _WhatsAppSettingPanel(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Automatizaciones',
                  description: 'Administra reglas para responder, etiquetar, asignar o notificar cuando ocurra un evento en WhatsApp.',
                  actionLabel: 'Crear automatización',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WhatsAppIntegrationPanel extends StatefulWidget {
  const _WhatsAppIntegrationPanel({required this.tenantId});

  final String tenantId;

  @override
  State<_WhatsAppIntegrationPanel> createState() =>
      _WhatsAppIntegrationPanelState();
}

class _WhatsAppIntegrationPanelState extends State<_WhatsAppIntegrationPanel> {
  final _businessIdController = TextEditingController();
  final _phoneIdController = TextEditingController();
  final _phoneController = TextEditingController();
  final _nameController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _validating = false;
  String _status = 'not_configured';
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _businessIdController.dispose();
    _phoneIdController.dispose();
    _phoneController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('tenant_integrations')
          .select('status, metadata')
          .eq('tenant_id', widget.tenantId)
          .eq('provider', 'whatsapp')
          .maybeSingle();
      if (row != null) {
        final metadata = Map<String, dynamic>.from(
          (row['metadata'] as Map?) ?? const {},
        );
        _status = row['status'] as String? ?? 'not_configured';
        _businessIdController.text =
            metadata['business_account_id'] as String? ?? '';
        _phoneIdController.text = metadata['phone_number_id'] as String? ?? '';
        _phoneController.text =
            metadata['display_phone_number'] as String? ?? '';
        _nameController.text = metadata['name'] as String? ?? '';
      }
    } on PostgrestException catch (error) {
      _message = error.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_businessIdController.text.trim().isEmpty ||
        _phoneIdController.text.trim().isEmpty) {
      setState(
        () => _message =
            'Business Account ID y Phone Number ID son obligatorios.',
      );
      return;
    }

    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await Supabase.instance.client.from('tenant_integrations').upsert({
        'tenant_id': widget.tenantId,
        'provider': 'whatsapp',
        'status': 'configuring',
        'metadata': {
          'business_account_id': _businessIdController.text.trim(),
          'phone_number_id': _phoneIdController.text.trim(),
          'display_phone_number': _phoneController.text.trim(),
          'name': _nameController.text.trim(),
        },
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'tenant_id,provider');
      if (mounted) {
        setState(() {
          _status = 'configuring';
          _message = 'Datos guardados. La conexión aún debe validarse desde el backend.';
        });
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _validateConnection() async {
    setState(() {
      _validating = true;
      _message = null;
    });
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'validate-whatsapp-integration',
        body: {'tenant_id': widget.tenantId},
      );
      final data = Map<String, dynamic>.from(
        (response.data as Map?) ?? const {},
      );
      if (mounted) {
        setState(() {
          _status = data['status'] as String? ?? 'error';
          _message =
              data['message'] as String? ??
              'La validación terminó sin un mensaje.';
        });
      }
    } on FunctionException catch (error) {
      if (mounted) {
        setState(
          () => _message =
              'No fue posible validar la conexión: ${error.details ?? error.reasonPhrase}',
        );
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Icon(
              Icons.link_outlined,
              size: 32,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Datos de la integración',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Chip(label: Text(_integrationStatusLabel(_status))),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Registra los identificadores públicos de Meta. Los tokens y secretos se gestionarán exclusivamente en backend.',
        ),
        const SizedBox(height: 24),
        _IntegrationField(
          controller: _businessIdController,
          label: 'WhatsApp Business Account ID',
        ),
        _IntegrationField(
          controller: _phoneIdController,
          label: 'Phone Number ID',
        ),
        _IntegrationField(
          controller: _phoneController,
          label: 'Número mostrado',
          required: false,
        ),
        _IntegrationField(
          controller: _nameController,
          label: 'Nombre del canal',
          required: false,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Guardando...' : 'Guardar integración'),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _validating ? null : _validateConnection,
            icon: const Icon(Icons.verified_outlined),
            label: Text(
              _validating ? 'Validando...' : 'Validar conexión con Meta',
            ),
          ),
        ),
        if (_message != null) ...[const SizedBox(height: 14), Text(_message!)],
      ],
    );
  }
}

String _integrationStatusLabel(String status) {
  switch (status) {
    case 'active':
      return 'Activa';
    case 'configuring':
      return 'Pendiente de validación';
    case 'error':
      return 'Con error';
    case 'disabled':
      return 'Deshabilitada';
    default:
      return 'No configurada';
  }
}

class _IntegrationField extends StatelessWidget {
  const _IntegrationField({
    required this.controller,
    required this.label,
    this.required = true,
  });

  final TextEditingController controller;
  final String label;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          suffixText: required ? '*' : null,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _WhatsAppSettingPanel extends StatelessWidget {
  const _WhatsAppSettingPanel({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(description),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Esta configuración aún no está creada para este tenant.',
                  ),
                ),
                OutlinedButton(onPressed: null, child: Text(actionLabel)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PersonalSettings extends StatelessWidget {
  const _PersonalSettings({
    required this.nameController,
    required this.avatarUrl,
    required this.saving,
    required this.uploading,
    required this.message,
    required this.onSave,
    required this.onPickAvatar,
  });

  final TextEditingController nameController;
  final String? avatarUrl;
  final bool saving;
  final bool uploading;
  final String? message;
  final VoidCallback onSave;
  final VoidCallback onPickAvatar;

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Información personal',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text('Administra la información visible de tu usuario.'),
        const SizedBox(height: 24),
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 42,
                backgroundImage: avatarUrl == null
                    ? null
                    : NetworkImage(avatarUrl!),
                child: avatarUrl != null
                    ? null
                    : Text(
                        (nameController.text.isEmpty
                                ? user?.email ?? 'U'
                                : nameController.text)
                            .substring(0, 1)
                            .toUpperCase(),
                        style: const TextStyle(fontSize: 28),
                      ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: uploading ? null : onPickAvatar,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(uploading ? 'Subiendo...' : 'Subir foto'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Nombre de la persona',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: user?.email ?? '',
          readOnly: true,
          decoration: const InputDecoration(
            labelText: 'Correo electrónico',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: saving ? null : onSave,
          icon: const Icon(Icons.save_outlined),
          label: Text(saving ? 'Guardando...' : 'Guardar información personal'),
        ),
        if (message != null) ...[const SizedBox(height: 12), Text(message!)],
      ],
    );
  }
}

class _CompanySettings extends StatelessWidget {
  const _CompanySettings({
    required this.tenant,
    required this.sector,
    required this.saving,
    required this.uploadingLogo,
    required this.message,
    required this.onSectorChanged,
    required this.onSave,
    required this.onPickLogo,
  });

  final Map<String, dynamic> tenant;
  final String sector;
  final bool saving;
  final bool uploadingLogo;
  final String? message;
  final ValueChanged<String> onSectorChanged;
  final VoidCallback onSave;
  final VoidCallback onPickLogo;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Información de la empresa',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Estos datos definirán la experiencia operativa del tenant.',
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(18),
                ),
                alignment: Alignment.center,
                child: (tenant['logo_url'] as String?) == null
                    ? Icon(
                        Icons.business_outlined,
                        size: 34,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.network(
                          tenant['logo_url'] as String,
                          fit: BoxFit.contain,
                          width: 76,
                          height: 76,
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Logo de la empresa',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text('Se mostrará en la barra superior de ITONE.'),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: uploadingLogo ? null : onPickLogo,
                      icon: const Icon(Icons.upload_outlined),
                      label: Text(uploadingLogo ? 'Subiendo...' : 'Subir logo'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextFormField(
          initialValue: tenant['name'] as String? ?? '',
          readOnly: true,
          decoration: const InputDecoration(
            labelText: 'Nombre de la empresa',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: sector,
          decoration: const InputDecoration(
            labelText: 'Sector de la empresa',
            border: OutlineInputBorder(),
          ),
          items: _tenantSectors.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(),
          onChanged: saving
              ? null
              : (value) {
                  if (value != null) onSectorChanged(value);
                },
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: saving ? null : onSave,
          icon: const Icon(Icons.save_outlined),
          label: Text(saving ? 'Guardando...' : 'Guardar sector'),
        ),
        if (message != null) ...[const SizedBox(height: 12), Text(message!)],
      ],
    );
  }
}

class _WhatsAppBusinessInbox extends StatelessWidget {
  const _WhatsAppBusinessInbox();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 480,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 320,
              child: Column(
                children: [
                  Container(
                    color: theme.colorScheme.primaryContainer,
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(
                          Icons.chat_outlined,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Bandeja de entrada',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Buscar conversación',
                          onPressed: null,
                          icon: const Icon(Icons.search),
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: TextField(
                      enabled: false,
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Buscar chats',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Aún no hay conversaciones.\nLos nuevos mensajes aparecerán aquí.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.forum_outlined,
                        size: 64,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Selecciona una conversación',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Aquí podrás leer y responder los mensajes de tus clientes.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 270,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(
                icon,
                size: 30,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value, style: Theme.of(context).textTheme.headlineSmall),
                  Text(title),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorPage extends StatelessWidget {
  const ErrorPage({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(message),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
            ],
          ],
        ),
      ),
    );
  }
}

class ConfigurationErrorPage extends StatelessWidget {
  const ConfigurationErrorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('La configuración de ITONE está incompleta.')),
    );
  }
}
