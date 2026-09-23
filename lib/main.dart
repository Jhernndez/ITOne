import 'package:flutter/material.dart';

void main() {
  runApp(const IToneApp());
}

class IToneApp extends StatelessWidget {
  const IToneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ITONE',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF176B87),
        ),
        useMaterial3: true,
      ),
      home: const IToneHomePage(),
    );
  }
}

class IToneHomePage extends StatelessWidget {
  const IToneHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'ITONE',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Plataforma de operaciones empresariales',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  'La fundación multitenant de ITONE está lista para comenzar.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
