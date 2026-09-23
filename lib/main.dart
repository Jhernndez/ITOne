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
        return const TenantOnboardingPage();
      },
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Empresa creada correctamente.')),
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
