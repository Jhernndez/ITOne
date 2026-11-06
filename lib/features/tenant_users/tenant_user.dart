import 'package:supabase_flutter/supabase_flutter.dart';

enum TenantRole {
  administrator('tenant_admin', 'Administrador'),
  supervisor('supervisor', 'Supervisor'),
  agent('operator', 'Agente');

  const TenantRole(this.value, this.label);
  final String value;
  final String label;

  static TenantRole parse(String value) =>
      values.firstWhere((role) => role.value == value);
}

class TenantUser {
  const TenantUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.active,
    required this.globallyDisabled,
    this.avatarUrl,
    this.lastSignIn,
    this.createdAt,
    this.canManageAccount = false,
  });

  factory TenantUser.fromJson(Map<String, dynamic> json) => TenantUser(
    id: json['user_id'] as String,
    email: json['email'] as String? ?? '',
    name: json['full_name'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    role: TenantRole.parse(json['role'] as String),
    active: json['is_active'] as bool,
    globallyDisabled: json['is_globally_disabled'] as bool,
    lastSignIn: DateTime.tryParse(json['last_sign_in_at'] as String? ?? ''),
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    canManageAccount: json['can_manage_account'] as bool? ?? false,
  );

  final String id;
  final String email;
  final String name;
  final String? avatarUrl;
  final TenantRole role;
  final bool active;
  final bool globallyDisabled;
  final DateTime? lastSignIn;
  final DateTime? createdAt;
  final bool canManageAccount;

  bool get effectiveActive => active && !globallyDisabled;
  String get displayName => name.trim().isNotEmpty
      ? name.trim()
      : email.isNotEmpty
      ? email.split('@').first
      : 'Usuario';
}

class TenantUserRepository {
  TenantUserRepository(this.client);
  final SupabaseClient client;

  String? get currentUserId => client.auth.currentUser?.id;

  Future<void> updateAccount(
    String tenantId,
    TenantUser user,
    String fullName,
    String? temporaryPassword,
  ) async {
    await client.functions.invoke(
      'manage-tenant-user',
      body: {
        'tenant_id': tenantId,
        'user_id': user.id,
        'full_name': fullName.trim(),
        'expected_name': user.name,
        'password': temporaryPassword,
      },
    );
  }

  Future<void> create(
    String tenantId,
    String fullName,
    String email,
    TenantRole role,
    String temporaryPassword,
  ) async {
    await client.functions.invoke(
      'create-tenant-user',
      body: {
        'tenant_id': tenantId,
        'full_name': fullName.trim(),
        'email': email.trim().toLowerCase(),
        'role': role.value,
        'password': temporaryPassword,
      },
    );
  }

  Future<List<TenantUser>> list(String tenantId) async {
    final rows = await client.rpc(
      'list_tenant_users',
      params: {'p_tenant_id': tenantId},
    ) as List;
    return rows
        .map(
          (row) => TenantUser.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  Future<void> update(
    String tenantId,
    TenantUser user,
    TenantRole role,
    bool active,
  ) async {
    await client.rpc(
      'update_tenant_user',
      params: {
        'p_tenant_id': tenantId,
        'p_user_id': user.id,
        'p_role': role.value,
        'p_is_active': active,
        'p_expected_role': user.role.value,
        'p_expected_active': user.active,
      },
    );
  }
}
