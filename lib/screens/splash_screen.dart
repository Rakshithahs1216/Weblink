import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../routes.dart';
import '../services/auth_service.dart';
import '../widgets/brand_mark.dart';

/// Shown while a stored token is validated with `GET /api/auth/me`.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final auth = context.read<AuthService>();
    try {
      await auth.bootstrap();
    } catch (e) {
      debugPrint('Session restore failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't restore your session. Please log in."),
        ),
      );
      Navigator.of(context).pushReplacementNamed(Routes.login);
      return;
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacementNamed(auth.isAuthenticated ? Routes.home : Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 72),
            const SizedBox(height: 24),
            Text('Weblink', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 24),
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 12),
            Text(
              'Restoring your session…',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
