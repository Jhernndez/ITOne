import 'package:flutter_test/flutter_test.dart';

import 'package:itone/main.dart';

void main() {
  testWidgets('shows the ITONE landing page', (WidgetTester tester) async {
    await tester.pumpWidget(const IToneApp(configurationError: true));

    expect(find.text('La configuración de ITONE está incompleta.'), findsOneWidget);
  });
}
