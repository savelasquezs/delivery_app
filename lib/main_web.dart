import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'core/api/api_constants.dart';

import 'main.dart' show DeliveryApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    dotenv.load(fileName: '.env'),
    initializeDateFormatting('es_CO'),
  ]);
  if (!{'localhost', '127.0.0.1', '::1'}.contains(Uri.parse(ApiConstants.baseUrl).host)) {
    throw StateError('La vista web de desarrollo requiere una API local.');
  }
  runApp(const ProviderScope(child: DeliveryApp()));
}
