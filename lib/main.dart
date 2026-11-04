import 'package:flutter/material.dart';

import 'app.dart';
import 'services/token_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(WeblinkApp(storage: SecureTokenStorage()));
}
