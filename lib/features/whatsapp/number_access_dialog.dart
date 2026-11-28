import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WhatsAppNumberAccessDialog extends StatefulWidget {
  const WhatsAppNumberAccessDialog({
    super.key,
    required this.tenantId,
    required this.userId,
    required this.userName,
    this.loadAccess,
    this.setAccess,
  });
  final String tenantId;
  final String userId;
  final String userName;
  final Future<({List<Map<String, dynamic>> accounts, Set<String> assigned})>
  Function(String tenantId, String userId)?
  loadAccess;
  final Future<void> Function(
    String tenantId,
    String accountId,
    String userId,
    bool allowed,
  )?
  setAccess;

  @override
  State<WhatsAppNumberAccessDialog> createState() =>
      _WhatsAppNumberAccessDialogState();
}

class _WhatsAppNumberAccessDialogState
    extends State<WhatsAppNumberAccessDialog> {
  late final _client = Supabase.instance.client;
  List<Map<String, dynamic>> _accounts = [];
  Set<String> _assigned = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loadAccess = widget.loadAccess;
      final List<Map<String, dynamic>> accounts;
      final Set<String> assigned;
      if (loadAccess != null) {
        final result = await loadAccess(widget.tenantId, widget.userId);
        accounts = result.accounts;
        assigned = result.assigned;
      } else {
        final rows = await _client
            .from('whatsapp_accounts')
            .select('id,name,display_phone_number')
            .eq('tenant_id', widget.tenantId);
        final access = await _client
            .from('whatsapp_number_access')
            .select('account_id')
            .eq('tenant_id', widget.tenantId)
            .eq('user_id', widget.userId);
        accounts = rows.map((row) => Map<String, dynamic>.from(row)).toList();
        assigned = access.map((row) => row['account_id'] as String).toSet();
      }
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _assigned = assigned;
        _loading = false;
        _error = null;
      });
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'No se pudieron consultar los permisos.';
        });
      }
    }
  }

  Future<void> _change(String accountId, bool allowed) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final setAccess = widget.setAccess;
      if (setAccess != null) {
        await setAccess(widget.tenantId, accountId, widget.userId, allowed);
      } else {
        await _client.rpc(
          'set_whatsapp_number_access',
          params: {
            'p_tenant_id': widget.tenantId,
            'p_account_id': accountId,
            'p_user_id': widget.userId,
            'p_allowed': allowed,
          },
        );
      }
      if (mounted) {
        setState(() {
          if (allowed) {
            _assigned.add(accountId);
          } else {
            _assigned.remove(accountId);
          }
        });
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo actualizar el permiso.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Números de ${widget.userName}'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Permite consultar y responder conversaciones por número. Los administradores tienen acceso a todos.',
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_accounts.isEmpty)
              const Text('No hay números conectados.')
            else
              for (final account in _accounts)
                SwitchListTile(
                  title: Text(account['name'] as String? ?? 'WhatsApp'),
                  subtitle: Text(
                    account['display_phone_number'] as String? ?? 'Sin número',
                  ),
                  value: _assigned.contains(account['id']),
                  onChanged: _saving
                      ? null
                      : (value) => _change(account['id'] as String, value),
                ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cerrar'),
      ),
    ],
  );
}
