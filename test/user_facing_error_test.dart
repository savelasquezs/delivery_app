import 'package:delivery_app/core/api/api_exception.dart';
import 'package:delivery_app/core/errors/user_facing_error.dart';
import 'package:delivery_app/core/widgets/error_banner.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('userFacingErrorMessage', () {
    test('preserva el mensaje útil de ApiException', () {
      expect(
        userFacingErrorMessage(
          const ApiException('La jornada fue cerrada por liquidación total.'),
        ),
        'La jornada fue cerrada por liquidación total.',
      );
    });

    test('extrae ApiException anidada en DioException', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/auth/login'),
        type: DioExceptionType.badResponse,
        error: const ApiException('La jornada no está disponible.'),
      );

      expect(
        userFacingErrorMessage(error),
        'La jornada no está disponible.',
      );
    });

    test('limpia el texto técnico que motivó el cambio', () {
      const raw = 'DioException [bad response]: null\n'
          'Error: La jornada fue cerrada por liquidación total. '
          'Un administrador debe habilitarla para continuar.';

      expect(
        userFacingErrorMessage(raw),
        'La jornada fue cerrada por liquidación total. '
        'Un administrador debe habilitarla para continuar.',
      );
    });

    test('usa el mensaje del servidor si Dio no trae error anidado', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/orders'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/orders'),
          statusCode: 409,
          data: {'message': 'El pedido ya fue asignado.'},
        ),
        type: DioExceptionType.badResponse,
      );

      expect(userFacingErrorMessage(error), 'El pedido ya fue asignado.');
    });

    test('oculta excepciones técnicas sin un mensaje útil', () {
      expect(
        userFacingErrorMessage(
          'SocketException: Failed host lookup',
          fallback: 'No pudimos cargar los pedidos.',
        ),
        'No pudimos cargar los pedidos.',
      );
    });

    test('limpia el prefijo de StateError', () {
      expect(
        userFacingErrorMessage(
            StateError('Activa la ubicación para continuar.')),
        'Activa la ubicación para continuar.',
      );
    });
  });

  testWidgets('ErrorBanner muestra solo el mensaje útil y permite reintentar',
      (tester) async {
    var retried = false;
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorBanner(
            title: 'No pudimos iniciar sesión',
            message: 'DioException [bad response]: null\n'
                'Error: La jornada fue cerrada por liquidación total.',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('No pudimos iniciar sesión'), findsOneWidget);
    expect(
      find.text('La jornada fue cerrada por liquidación total.'),
      findsOneWidget,
    );
    expect(find.textContaining('DioException'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Intentar de nuevo'));
    expect(retried, isTrue);
  });
}
