import 'package:flutter_test/flutter_test.dart';

import 'package:itone/main.dart';

void main() {
  testWidgets('shows the ITONE landing page', (WidgetTester tester) async {
    await tester.pumpWidget(const IToneApp());

    expect(find.text('ITONE'), findsOneWidget);
    expect(
      find.text('Plataforma de operaciones empresariales'),
      findsOneWidget,
    );
  });
}
