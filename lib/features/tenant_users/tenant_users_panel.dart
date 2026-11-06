import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_user.dart';

class TenantUsersPanel extends StatefulWidget {
  const TenantUsersPanel({
    super.key,
    required this.tenantId,
    required this.tenantName,
    this.repository,
  });

  final String tenantId;
  final String tenantName;
  final TenantUserRepository? repository;

  @override
  State<TenantUsersPanel> createState() => _TenantUsersPanelState();
}

class _TenantUsersPanelState extends State<TenantUsersPanel> {
  late final _repository =
      widget.repository ?? TenantUserRepository(Supabase.instance.client);
  final _search = TextEditingController();
  List<TenantUser> _users = [];
  TenantRole? _roleFilter;
  String _statusFilter = 'all';
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _message;
  int _tab = 0;
  int _page = 0;
  static const _pageSize = 8;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await _repository.list(widget.tenantId);
      if (!mounted) return;
      setState(() {
        _users = users;
        _page = 0;
      });
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(() {
          _users = [];
          _error = error.message;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _users = [];
          _error = 'No fue posible cargar los usuarios: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<TenantUser> get _filtered {
    final query = _search.text.trim().toLowerCase();
    return _users
        .where(
          (user) =>
              (_roleFilter == null || user.role == _roleFilter) &&
              (_statusFilter == 'all' ||
                  (_statusFilter == 'active'
                      ? user.effectiveActive
                      : !user.effectiveActive)) &&
              (query.isEmpty ||
                  '${user.displayName} ${user.email} ${user.role.label}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
  }

  Future<void> _create() async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    var role = TenantRole.agent;
    var obscure = true;
    var submitting = false;
    String? error;
    var created = false;
    try {
      final route = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => PopScope(
            canPop: !submitting,
            child: AlertDialog(
              title: const Text('Crear usuario'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Acceso únicamente a ${widget.tenantName}.'),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: name,
                          enabled: !submitting,
                          maxLength: 120,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Nombre completo',
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Ingresa el nombre.'
                              : null,
                        ),
                        TextFormField(
                          controller: email,
                          enabled: !submitting,
                          maxLength: 254,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Correo electrónico',
                          ),
                          validator: (value) =>
                              !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                  .hasMatch(value?.trim() ?? '')
                              ? 'Ingresa un correo válido.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<TenantRole>(
                          initialValue: role,
                          decoration: const InputDecoration(labelText: 'Rol'),
                          items: TenantRole.values
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: entry,
                                  child: Text(entry.label),
                                ),
                              )
                              .toList(),
                          onChanged: submitting
                              ? null
                              : (value) {
                                  if (value != null) update(() => role = value);
                                },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: password,
                          enabled: !submitting,
                          obscureText: obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLength: 128,
                          decoration: InputDecoration(
                            labelText: 'Contraseña temporal',
                            helperText: '12 a 128 caracteres, mayúscula, minúscula y número.',
                            helperMaxLines: 2,
                            suffixIcon: IconButton(
                              tooltip: obscure
                                  ? 'Mostrar contraseña'
                                  : 'Ocultar contraseña',
                              onPressed: submitting
                                  ? null
                                  : () => update(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (value) {
                            final text = value ?? '';
                            return text.length < 12 ||
                                    text.length > 128 ||
                                    !RegExp('[a-z]').hasMatch(text) ||
                                    !RegExp('[A-Z]').hasMatch(text) ||
                                    !RegExp('[0-9]').hasMatch(text)
                                ? 'Usa al menos 12 caracteres, mayúscula, minúscula y número.'
                                : null;
                          },
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Comparte la contraseña por un medio seguro. No se envía correo. '
                          'Al entrar deberá cambiarla. Si el correo ya existe en ITONE, '
                          'no se creará ni se vinculará la cuenta.',
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          update(() {
                            submitting = true;
                            error = null;
                          });
                          try {
                            await _repository.create(
                              widget.tenantId,
                              name.text,
                              email.text,
                              role,
                              password.text,
                            );
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext, true);
                            }
                          } on FunctionException catch (failure) {
                            if (dialogContext.mounted) {
                              final details = failure.details;
                              update(
                                () => error =
                                    details is Map && details['error'] is String
                                    ? details['error'] as String
                                    : 'No fue posible crear el usuario. ${failure.reasonPhrase ?? ''}',
                              );
                            }
                          } catch (failure) {
                            if (dialogContext.mounted) {
                              update(
                                () => error =
                                    'No fue posible crear el usuario: $failure',
                              );
                            }
                          } finally {
                            if (dialogContext.mounted) {
                              update(() => submitting = false);
                            }
                          }
                        },
                  child: Text(submitting ? 'Creando...' : 'Crear usuario'),
                ),
              ],
            ),
          ),
        ),
      );
      created = await Navigator.of(context).push(route) ?? false;
      await route.completed;
    } finally {
      name.dispose();
      email.dispose();
      password.dispose();
    }
    if (!created || !mounted) return;
    setState(() {
      _search.clear();
      _roleFilter = null;
      _statusFilter = 'all';
      _message =
          'Usuario creado. Comparte la contraseña temporal de forma segura.';
    });
    await _load();
  }

  Future<void> _edit(TenantUser user) async {
    var role = user.role;
    var active = user.active;
    var editAccount = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Editar acceso'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(user.email),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: user.canManageAccount
                      ? () {
                          editAccount = true;
                          Navigator.pop(context, false);
                        }
                      : null,
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: const Text('Nombre y contraseña'),
                ),
                if (!user.canManageAccount)
                  const Text(
                    'Cuenta compartida, de plataforma o bloqueada. '
                    'El nombre y la contraseña se gestionan desde plataforma.',
                  ),
                const SizedBox(height: 20),
                DropdownButtonFormField<TenantRole>(
                  initialValue: role,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Rol',
                    border: OutlineInputBorder(),
                  ),
                  items: TenantRole.values
                      .map(
                        (role) => DropdownMenuItem(
                          value: role,
                          child: Text(role.label),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) update(() => role = value);
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Acceso activo a esta empresa'),
                  value: active,
                  onChanged: (value) => update(() => active = value),
                ),
                Text(
                  'Solo afecta a ${widget.tenantName}. No bloquea su cuenta '
                  'global ni el acceso a otras empresas.',
                ),
                if (user.globallyDisabled) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'La cuenta está bloqueada a nivel de plataforma. Activar '
                    'esta membresía no elimina ese bloqueo.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Guardar cambios'),
            ),
          ],
        ),
      ),
    );
    if (editAccount && mounted) {
      await _editAccount(user);
      return;
    }
    if (confirmed == true && (role != user.role || active != user.active)) {
      await _save(user, role, active);
    }
  }

  Future<void> _editAccount(TenantUser user) async {
    final name = TextEditingController(text: user.name);
    final password = TextEditingController();
    final form = GlobalKey<FormState>();
    var saving = false;
    var obscure = true;
    String? error;
    bool saved;
    try {
      final route = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: const Text('Editar nombre y contraseña'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Form(
                    key: form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(user.email),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: name,
                          enabled: !saving,
                          maxLength: 120,
                          decoration: const InputDecoration(
                            labelText: 'Nombre completo',
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Ingresa el nombre.'
                              : null,
                        ),
                        TextFormField(
                          controller: password,
                          enabled: !saving,
                          obscureText: obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Nueva contraseña temporal (opcional)',
                            helperText:
                                'Vacío: conserva la actual. Mínimo 12 caracteres, '
                                'mayúscula, minúscula y número. Máximo 72 bytes.',
                            helperMaxLines: 3,
                            suffixIcon: IconButton(
                              tooltip: obscure
                                  ? 'Mostrar contraseña'
                                  : 'Ocultar contraseña',
                              onPressed: saving
                                  ? null
                                  : () => update(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (value) {
                            final text = value ?? '';
                            if (text.isEmpty) return null;
                            return text.length < 12 ||
                                    utf8.encode(text).length > 72 ||
                                    !RegExp('[a-z]').hasMatch(text) ||
                                    !RegExp('[A-Z]').hasMatch(text) ||
                                    !RegExp('[0-9]').hasMatch(text)
                                ? 'Usa 12 caracteres, mayúscula, minúscula y número; máximo 72 bytes.'
                                : null;
                          },
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Solo disponible para cuentas exclusivas de esta empresa. '
                          'Si asignas una contraseña temporal, comparte la nueva clave '
                          'por un medio seguro. El usuario deberá cambiarla al entrar; '
                          'su acceso a los datos queda bloqueado hasta entonces.',
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          update(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            await _repository.updateAccount(
                              widget.tenantId,
                              user,
                              name.text,
                              password.text.isEmpty ? null : password.text,
                            );
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext, true);
                            }
                          } on FunctionException catch (failure) {
                            if (dialogContext.mounted) {
                              final details = failure.details;
                              update(
                                () => error =
                                    details is Map && details['error'] is String
                                    ? details['error'] as String
                                    : 'No fue posible editar la cuenta. ${failure.reasonPhrase ?? ''}',
                              );
                            }
                          } catch (failure) {
                            if (dialogContext.mounted) {
                              update(
                                () => error =
                                    'No fue posible editar la cuenta: $failure',
                              );
                            }
                          } finally {
                            if (dialogContext.mounted) {
                              update(() => saving = false);
                            }
                          }
                        },
                  child: Text(saving ? 'Guardando...' : 'Guardar cuenta'),
                ),
              ],
            ),
          ),
        ),
      );
      saved = await Navigator.of(context).push(route) ?? false;
      await route.completed;
    } finally {
      name.dispose();
      password.dispose();
    }
    if (!saved || !mounted) return;
    setState(
      () => _message =
          'Cuenta actualizada. Si asignaste una contraseña temporal, '
          'compártela de forma segura; el usuario deberá cambiarla al entrar.',
    );
    await _load();
  }

  Future<void> _toggle(TenantUser user) async {
    final action = user.active ? 'Desactivar' : 'Activar';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$action acceso'),
        content: Text(
          '$action el acceso de ${user.displayName} a ${widget.tenantName}. '
          'Sus datos se conservan y sus otras empresas no se modifican.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (confirmed == true) await _save(user, user.role, !user.active);
  }

  Future<void> _save(TenantUser user, TenantRole role, bool active) async {
    if (!mounted || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });
    try {
      await _repository.update(widget.tenantId, user, role, active);
      if (!mounted) return;
      setState(() => _message = 'Acceso de ${user.displayName} actualizado.');
      await _load();
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No fue posible guardar el acceso: $error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _details(TenantUser user) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(user.displayName),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(user.email),
              const SizedBox(height: 14),
              Text('Empresa: ${widget.tenantName}'),
              Text('Rol: ${user.role.label}'),
              Text(
                'Acceso a la empresa: ${user.active ? "Activo" : "Inactivo"}',
              ),
              Text(
                'Cuenta global: ${user.globallyDisabled ? "Bloqueada" : "Sin bloqueo"}',
              ),
              Text('Miembro desde: ${_date(user.createdAt)}'),
              Text('Último inicio de sesión: ${_date(user.lastSignIn)}'),
              const SizedBox(height: 12),
              const Text(
                'El inicio de sesión corresponde a la cuenta de ITONE, no a una visita a esta empresa.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [Color(0xFFE7F0FF), Color(0xFFF4F8FF)],
          ),
          border: Border.all(color: const Color(0xFFD8E5FA)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.verified_user_outlined,
              color: Color(0xFF1765CE),
              size: 40,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gestiona el acceso de tu equipo',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text('Usuarios, roles y permisos de ${widget.tenantName}.'),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Actualizar usuarios',
              onPressed: _loading || _saving ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _loading || _saving ? null : _create,
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Crear usuario'),
        ),
      ),
      const SizedBox(height: 12),
      if (_error != null) ...[
        _notice(_error!, error: true),
        const SizedBox(height: 12),
      ],
      if (_message != null) ...[_notice(_message!), const SizedBox(height: 12)],
      LayoutBuilder(
        builder: (context, constraints) {
          final content = _mainCard();
          final summary = _summary();
          if (constraints.maxWidth < 1050) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 16), content],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: content),
              const SizedBox(width: 18),
              SizedBox(width: 255, child: summary),
            ],
          );
        },
      ),
    ],
  );

  Widget _notice(String message, {bool error = false}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: error ? const Color(0xFFFFECEC) : const Color(0xFFE8F4EE),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(
          error ? Icons.error_outline : Icons.check_circle_outline,
          color: error ? Colors.red.shade700 : Colors.green.shade700,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
        if (error)
          TextButton(
            onPressed: _loading || _saving ? null : _load,
            child: const Text('Reintentar'),
          ),
      ],
    ),
  );

  Widget _mainCard() => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          children: [
            for (final (index, label, icon) in [
              (0, 'Usuarios', Icons.people_alt_outlined),
              (1, 'Roles', Icons.shield_outlined),
              (2, 'Permisos', Icons.lock_outline),
            ])
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: _tab == index
                      ? const Color(0xFF1765CE)
                      : Colors.blueGrey,
                  backgroundColor: _tab == index
                      ? const Color(0xFFEAF2FF)
                      : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                  shape: const RoundedRectangleBorder(),
                ),
                onPressed: () => setState(() => _tab = index),
                icon: Icon(icon, size: 19),
                label: Text(label),
              ),
          ],
        ),
        const Divider(height: 1),
        if (_saving || _loading) const LinearProgressIndicator(),
        if (_tab == 0) _usersTab(),
        if (_tab == 1) _rolesTab(),
        if (_tab == 2) _permissionsTab(),
      ],
    ),
  );

  Widget _usersTab() {
    final filtered = _filtered;
    final pages = math.max(1, (filtered.length / _pageSize).ceil());
    final currentPage = math.min(_page, pages - 1);
    final start = currentPage * _pageSize;
    final visible = filtered.skip(start).take(_pageSize).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final search = TextField(
                controller: _search,
                onChanged: (_) => setState(() => _page = 0),
                decoration: const InputDecoration(
                  hintText: 'Buscar por nombre, correo o rol...',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              );
              final filters = Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  DropdownMenu<TenantRole?>(
                    initialSelection: _roleFilter,
                    width: 180,
                    label: const Text('Rol'),
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(
                        value: null,
                        label: 'Todos los roles',
                      ),
                      ...TenantRole.values.map(
                        (role) =>
                            DropdownMenuEntry(value: role, label: role.label),
                      ),
                    ],
                    onSelected: (role) => setState(() {
                      _roleFilter = role;
                      _page = 0;
                    }),
                  ),
                  DropdownMenu<String>(
                    initialSelection: _statusFilter,
                    width: 180,
                    label: const Text('Estado'),
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(
                        value: 'all',
                        label: 'Todos los estados',
                      ),
                      DropdownMenuEntry(value: 'active', label: 'Activos'),
                      DropdownMenuEntry(value: 'inactive', label: 'Inactivos'),
                    ],
                    onSelected: (value) => setState(() {
                      _statusFilter = value ?? 'all';
                      _page = 0;
                    }),
                  ),
                ],
              );
              if (constraints.maxWidth < 800) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [search, const SizedBox(height: 14), filters],
                );
              }
              return Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 12),
                  filters,
                ],
              );
            },
          ),
        ),
        if (!_loading && _users.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'No hay usuarios asignados a esta empresa. Las altas se gestionan desde administración de plataforma.',
            ),
          )
        else if (!_loading && filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('No hay usuarios que coincidan con los filtros.'),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: DataTable(
                  headingRowColor: const WidgetStatePropertyAll(
                    Color(0xFFF0F5FC),
                  ),
                  dataRowMinHeight: 68,
                  dataRowMaxHeight: 76,
                  columnSpacing: 22,
                  columns: const [
                    DataColumn(label: Text('Usuario')),
                    DataColumn(label: Text('Rol')),
                    DataColumn(label: Text('Estado')),
                    DataColumn(
                      label: Tooltip(
                        message: 'Inicio de sesión global en ITONE, no último acceso a esta empresa',
                        child: Text('Último inicio de sesión'),
                      ),
                    ),
                    DataColumn(label: Text('Acciones')),
                  ],
                  rows: visible.map((user) {
                    final self = user.id == _repository.currentUserId;
                    return DataRow(
                      cells: [
                        DataCell(
                          SizedBox(
                            width: 225,
                            child: Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: const Color(0xFFE3EDFB),
                                  child: user.avatarUrl == null
                                      ? Text(
                                          user.displayName
                                              .substring(0, 1)
                                              .toUpperCase(),
                                        )
                                      : ClipOval(
                                          child: Image.network(
                                            user.avatarUrl!,
                                            width: 40,
                                            height: 40,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) => Text(
                                              user.displayName
                                                  .substring(0, 1)
                                                  .toUpperCase(),
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${user.displayName}${self ? " (tú)" : ""}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        user.email,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        DataCell(
                          _badge(user.role.label, _roleColor(user.role)),
                        ),
                        DataCell(
                          _badge(
                            user.globallyDisabled
                                ? 'Bloqueo global'
                                : user.active
                                ? 'Activo'
                                : 'Inactivo',
                            user.effectiveActive ? Colors.green : Colors.red,
                          ),
                        ),
                        DataCell(Text(_date(user.lastSignIn))),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Ver ${user.displayName}',
                                icon: const Icon(
                                  Icons.visibility_outlined,
                                  size: 19,
                                ),
                                onPressed: () => _details(user),
                              ),
                              IconButton(
                                tooltip: self
                                    ? 'No puedes editar tu propio acceso'
                                    : 'Editar ${user.displayName}',
                                icon: const Icon(Icons.edit_outlined, size: 19),
                                onPressed: self || _saving || _loading
                                    ? null
                                    : () => _edit(user),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Más acciones de ${user.displayName}',
                                enabled: !self && !_saving && !_loading,
                                onSelected: (_) => _toggle(user),
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'toggle',
                                    child: Text(
                                      user.active
                                          ? 'Desactivar acceso'
                                          : 'Activar acceso',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Mostrando ${filtered.isEmpty ? 0 : start + 1}–${start + visible.length} de ${filtered.length} usuarios',
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Página anterior',
                    onPressed: currentPage == 0
                        ? null
                        : () => setState(() => _page = currentPage - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${currentPage + 1} / $pages'),
                  IconButton(
                    tooltip: 'Página siguiente',
                    onPressed: currentPage >= pages - 1
                        ? null
                        : () => setState(() => _page = currentPage + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rolesTab() => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Roles fijos de la empresa',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        const SizedBox(height: 6),
        const Text(
          'Los permisos se asignan por rol. No hay roles personalizados ni excepciones individuales.',
        ),
        const SizedBox(height: 16),
        for (final role in TenantRole.values)
          Card(
            color: _roleColor(role).withValues(alpha: 0.06),
            child: ListTile(
              leading: Icon(_roleIcon(role), color: _roleColor(role)),
              title: Text(role.label),
              subtitle: Text(switch (role) {
                TenantRole.administrator => 'Configura la empresa e integraciones y administra el acceso del equipo.',
                TenantRole.supervisor => 'Atiende WhatsApp y accede a las vistas operativas y de reportes.',
                TenantRole.agent => 'Atiende conversaciones de WhatsApp y accede a las vistas operativas.',
              }),
              trailing: Text(
                '${_users.where((user) => user.role == role).length}',
              ),
            ),
          ),
      ],
    ),
  );

  Widget _permissionsTab() => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Permisos por rol',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        const SizedBox(height: 6),
        const Text(
          'Matriz de referencia del comportamiento actual. Un acceso inactivo no concede permisos en esta empresa.',
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [
              const DataColumn(label: Text('Acción')),
              for (final role in TenantRole.values)
                DataColumn(label: Text(role.label)),
            ],
            rows: [
              for (final (label, roles) in [
                ('Consultar bandeja de WhatsApp', TenantRole.values),
                ('Enviar mensajes de WhatsApp', TenantRole.values),
                (
                  'Configurar empresa e integraciones',
                  [TenantRole.administrator],
                ),
                (
                  'Consultar y gestionar accesos del equipo',
                  [TenantRole.administrator],
                ),
                (
                  'Abrir reportes (demostración)',
                  [TenantRole.administrator, TenantRole.supervisor],
                ),
                (
                  'Consultar y probar flujos (simulación)',
                  [TenantRole.administrator, TenantRole.supervisor],
                ),
                (
                  'Editar y publicar flujos para simulación',
                  [TenantRole.administrator],
                ),
              ])
                DataRow(
                  cells: [
                    DataCell(Text(label)),
                    for (final role in TenantRole.values)
                      DataCell(
                        Icon(
                          roles.contains(role)
                              ? Icons.check_circle
                              : Icons.remove_circle_outline,
                          color: roles.contains(role)
                              ? Colors.green
                              : Colors.blueGrey.shade300,
                          semanticLabel: roles.contains(role)
                              ? 'Permitido'
                              : 'No permitido',
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Clientes, tickets, agenda, dashboard y reportes mantienen sus vistas de '
          'demostración; esta pantalla no habilita operaciones reales en esos módulos. '
          'Los accesos de plataforma se administran fuera de esta empresa.',
        ),
      ],
    ),
  );

  Widget _summary() => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bar_chart, color: Color(0xFF1765CE)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Resumen de permisos',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            _loading
                ? '…'
                : '${_users.where((user) => user.effectiveActive).length}',
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
          ),
          const Text('Usuarios con acceso activo'),
          const SizedBox(height: 18),
          for (final role in TenantRole.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(_roleIcon(role), color: _roleColor(role), size: 19),
                  const SizedBox(width: 8),
                  Expanded(child: Text(role.label)),
                  Text(
                    _loading
                        ? '—'
                        : '${_users.where((user) => user.role == role && user.effectiveActive).length}',
                  ),
                ],
              ),
            ),
          const Divider(),
          Text('${_users.length} miembros en total'),
          const SizedBox(height: 8),
          const Text(
            'Desactivar el acceso no elimina al usuario. No puedes cambiar tu '
            'propio acceso ni dejar a la empresa sin administrador activo.',
          ),
        ],
      ),
    ),
  );
}

Color _roleColor(TenantRole role) => switch (role) {
  TenantRole.administrator => const Color(0xFF1765CE),
  TenantRole.supervisor => const Color(0xFF8055C8),
  TenantRole.agent => const Color(0xFF008C9E),
};

IconData _roleIcon(TenantRole role) => switch (role) {
  TenantRole.administrator => Icons.admin_panel_settings_outlined,
  TenantRole.supervisor => Icons.shield_outlined,
  TenantRole.agent => Icons.headset_mic_outlined,
};

Widget _badge(String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: 0.1),
    borderRadius: BorderRadius.circular(20),
  ),
  child: Text(
    label,
    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
  ),
);

String _date(DateTime? date) {
  if (date == null) return 'Sin registro';
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
}
