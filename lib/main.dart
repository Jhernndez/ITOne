import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabasePublishableKey =
    String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B87)),
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
          data: {
            ...?user.userMetadata,
            'platform_invitation_accepted': true,
          },
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

  bool get isEmpty =>
      tenantMemberships.isEmpty && platformMembership == null;
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
              const Text('Elige si deseas administrar la plataforma o una empresa.'),
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
                  title: (membership['tenants'] as Map<String, dynamic>)['name']
                      as String,
                  subtitle:
                      'Identificador: ${(membership['tenants'] as Map<String, dynamic>)['slug']} · Rol: ${membership['role']}',
                  icon: Icons.business,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TenantWorkspacePage(
                        membership: membership,
                      ),
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
                Text('Administración de plataforma',
                    style: Theme.of(context).textTheme.headlineMedium),
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
  List<Map<String, dynamic>> _invitations = [];
  List<Map<String, dynamic>> _accessUsers = [];
  bool _loading = true;
  bool _sending = false;
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
      final tenants =
          await client.from('tenants').select('id, name, slug').order('name');
      final invitations = await client
          .from('platform_invitations')
          .select(
            'id, email, platform_role, tenant_id, tenant_role, status, expires_at',
          )
          .order('created_at', ascending: false);
      final accessUsers =
          await client.rpc('list_platform_access') as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _tenants = List<Map<String, dynamic>>.from(tenants);
        _invitations = List<Map<String, dynamic>>.from(invitations);
        _accessUsers = accessUsers
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
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
      _sending = true;
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
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _revokeInvitation(String invitationId) async {
    setState(() {
      _error = null;
      _message = null;
    });
    try {
      await Supabase.instance.client.rpc(
        'revoke_platform_invitation',
        params: {'p_invitation_id': invitationId},
      );
      if (mounted) {
        setState(() => _message = 'Invitación cancelada.');
        await _loadData();
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No fue posible cancelar la invitación.\n$error');
      }
    }
  }

  Future<void> _updateAccess({
    required String userId,
    required String? platformRole,
    required String? tenantId,
    required String? tenantRole,
    required String? currentTenantId,
  }) async {
    try {
      await Supabase.instance.client.rpc(
        'update_platform_access',
        params: {
          'p_user_id': userId,
          'p_platform_role': platformRole,
          'p_tenant_id': tenantId,
          'p_tenant_role': tenantRole,
          'p_current_tenant_id': currentTenantId,
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

  String _tenantName(String? id) {
    if (id == null) return 'Sin tenant específico';
    for (final tenant in _tenants) {
      if (tenant['id'] == id) return tenant['name'] as String;
    }
    return 'Tenant no disponible';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Invitaciones y accesos')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              Text('Invitar usuario',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text(
                'El usuario recibirá un correo y obtendrá solo los accesos que definas.',
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Correo del invitado',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _platformRole,
                decoration: const InputDecoration(
                  labelText: 'Acceso de plataforma (opcional)',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Solo acceso al tenant seleccionado'),
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
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _tenantId,
                decoration: const InputDecoration(
                  labelText: 'Tenant autorizado (opcional)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Sin tenant específico'),
                  ),
                  ..._tenants.map(
                    (tenant) => DropdownMenuItem<String?>(
                      value: tenant['id'] as String,
                      child: Text(tenant['name'] as String),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _tenantId = value),
              ),
              if (_tenantId != null) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _tenantRole,
                  decoration: const InputDecoration(
                    labelText: 'Rol dentro del tenant',
                    border: OutlineInputBorder(),
                  ),
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
                  onChanged: (value) => setState(() => _tenantRole = value!),
                ),
              ],
              const SizedBox(height: 20),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Colors.red[700])),
              if (_message != null)
                Text(_message!, style: TextStyle(color: Colors.green[700])),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _sending ? null : _sendInvitation,
                icon: const Icon(Icons.send),
                label: Text(_sending ? 'Enviando...' : 'Enviar invitación'),
              ),
              const SizedBox(height: 36),
              Text('Usuarios y permisos',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (_accessUsers.isEmpty)
                const Text('No hay usuarios con accesos asignados.')
              else
                ..._accessUsers.map(
                  (access) => _AccessUserCard(
                    access: access,
                    tenants: _tenants,
                    onSave: _updateAccess,
                  ),
                ),
              const SizedBox(height: 36),
              Text('Invitaciones recientes',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (_invitations.isEmpty)
                const Text('No hay invitaciones registradas.')
              else
                ..._invitations.map(
                  (invitation) {
                    final isPending = invitation['status'] == 'pending';
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: Text(invitation['email'] as String),
                        subtitle: Text(
                          '${invitation['platform_role']} · ${_tenantName(invitation['tenant_id'] as String?)} · ${invitation['status']}',
                        ),
                        trailing: isPending
                            ? IconButton(
                                tooltip: 'Cancelar invitación',
                                icon: const Icon(Icons.cancel_outlined),
                                onPressed: () => _confirmRevoke(
                                  invitation['id'] as String,
                                  invitation['email'] as String,
                                ),
                              )
                            : null,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRevoke(String invitationId, String email) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar invitación'),
        content: Text(
          '¿Deseas cancelar la invitación enviada a $email? '
          'El enlace dejará de ser válido.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Conservar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancelar invitación'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _revokeInvitation(invitationId);
    }
  }
}

class _AccessUserCard extends StatefulWidget {
  const _AccessUserCard({
    required this.access,
    required this.tenants,
    required this.onSave,
  });

  final Map<String, dynamic> access;
  final List<Map<String, dynamic>> tenants;
  final Future<void> Function({
    required String userId,
    required String? platformRole,
    required String? tenantId,
    required String? tenantRole,
    required String? currentTenantId,
  }) onSave;

  @override
  State<_AccessUserCard> createState() => _AccessUserCardState();
}

class _AccessUserCardState extends State<_AccessUserCard> {
  late String? _platformRole = widget.access['platform_role'] as String?;
  late String? _tenantId = widget.access['tenant_id'] as String?;
  late String? _tenantRole = widget.access['tenant_role'] as String?;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final email = widget.access['email'] as String? ?? 'Usuario';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _tenantId,
              decoration: const InputDecoration(
                labelText: 'Tenant',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Sin acceso a tenant'),
                ),
                ...widget.tenants.map(
                  (tenant) => DropdownMenuItem<String?>(
                    value: tenant['id'] as String,
                    child: Text(tenant['name'] as String),
                  ),
                ),
              ],
              onChanged: (value) => setState(() {
                _tenantId = value;
                if (value == null) _tenantRole = null;
              }),
            ),
            if (_tenantId != null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _tenantRole,
                decoration: const InputDecoration(
                  labelText: 'Rol dentro del tenant',
                  border: OutlineInputBorder(),
                ),
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
                onChanged: (value) => setState(() => _tenantRole = value),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving
                    ? null
                    : () async {
                        setState(() => _saving = true);
                        await widget.onSave(
                          userId: widget.access['user_id'] as String,
                          platformRole: _platformRole,
                          tenantId: _tenantId,
                          tenantRole: _tenantRole,
                          currentTenantId:
                              widget.access['tenant_id'] as String?,
                        );
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
      setState(() => _error = 'La contraseña debe tener al menos 8 caracteres.');
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
          data: {
            ...?user.userMetadata,
            'must_set_password': false,
          },
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TenantRouter()),
      );
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'No fue posible guardar la contraseña.\n$error');
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
                  Text(title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
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
                    Text(_message!,
                        style: TextStyle(color: Colors.green[700])),
                  if (_error != null || _message != null)
                    const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: Text(_loading
                        ? 'Procesando...'
                        : _isRegistration
                            ? 'Crear cuenta'
                            : 'Iniciar sesión'),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() {
                              _isRegistration = !_isRegistration;
                              _error = null;
                              _message = null;
                            }),
                    child: Text(_isRegistration
                        ? 'Ya tengo una cuenta'
                        : 'Crear una cuenta empresarial'),
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
      setState(() => _error =
          'Indica el nombre y un identificador de 3 a 40 caracteres (a-z, 0-9 o -).');
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
              membership: {
                'tenant_id': tenantId,
                'role': 'tenant_admin',
              },
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
                Text('Configura tu empresa',
                    style: Theme.of(context).textTheme.headlineMedium),
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
        .select('id, name, slug, created_at')
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
        return Scaffold(
          appBar: AppBar(
            title: Text(tenant['name'] as String),
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
                      'Espacio empresarial',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Este contenido pertenece exclusivamente a tu tenant.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 28),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.business),
                        title: Text(tenant['name'] as String),
                        subtitle: Text(
                          'Identificador: ${tenant['slug']}\nRol: ${membership['role']}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
      body: Center(
        child: Text('La configuración de ITONE está incompleta.'),
      ),
    );
  }
}
