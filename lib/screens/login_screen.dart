import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../routes.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../widgets/brand_mark.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final TextEditingController _serverUrl;
  final _passwordFocus = FocusNode();

  bool _obscure = true;
  bool _loading = false;
  bool _showServerSettings = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _serverUrl = TextEditingController(text: auth.serverUrl);
    _error = auth.sessionMessage;
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _serverUrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    FocusScope.of(context).unfocus();
    if (AppConfig.validateServerUrl(_serverUrl.text) != null) {
      setState(() => _showServerSettings = true);
    }
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthService>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await auth.login(
        username: _username.text,
        password: _password.text,
        serverUrl: _serverUrl.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(Routes.home);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _fillDemo() {
    _username.text = 'demo';
    _password.text = 'demo1234';
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: BrandMark(size: 64)),
                      const SizedBox(height: 20),
                      Text(
                        'Welcome to Weblink',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Sign in to stream video and drive your robot.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        key: const Key('login.username'),
                        controller: _username,
                        enabled: !_loading,
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email,
                        ],
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                        decoration: const InputDecoration(
                          labelText: 'Username or email',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter your username or email'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('login.password'),
                        controller: _password,
                        focusNode: _passwordFocus,
                        enabled: !_loading,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure
                                ? 'Show password'
                                : 'Hide password',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Enter your password'
                            : null,
                      ),
                      const SizedBox(height: 8),
                      _ServerSettings(
                        controller: _serverUrl,
                        expanded: _showServerSettings,
                        enabled: !_loading,
                        onToggle: () => setState(
                          () => _showServerSettings = !_showServerSettings,
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        child: _error == null
                            ? const SizedBox(width: double.infinity)
                            : Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: _ErrorBanner(message: _error!),
                              ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const Key('login.submit'),
                        onPressed: _loading ? null : _submit,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: _loading
                              ? SizedBox.square(
                                  key: const ValueKey('spinner'),
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: scheme.onPrimary,
                                    semanticsLabel: 'Signing in',
                                  ),
                                )
                              : const Text('Log in', key: ValueKey('label')),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _loading ? null : _fillDemo,
                        icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                        label: const Text('Use demo account (demo / demo1234)'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Collapsible "Server settings" section. The field stays mounted while
/// collapsed so the form still validates it.
class _ServerSettings extends StatelessWidget {
  const _ServerSettings({
    required this.controller,
    required this.expanded,
    required this.enabled,
    required this.onToggle,
  });

  final TextEditingController controller;
  final bool expanded;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.dns_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text('Server settings', style: theme.textTheme.labelLarge),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    expanded ? '' : controller.text,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more),
                ),
              ],
            ),
          ),
        ),
        Visibility(
          visible: expanded,
          maintainState: true,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextFormField(
              key: const Key('login.server'),
              controller: controller,
              enabled: enabled,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Server URL',
                prefixIcon: const Icon(Icons.link),
                helperText:
                    'Android emulator: http://10.0.2.2:8010 · '
                    'Default: ${AppConfig.defaultServerUrl}',
                helperMaxLines: 2,
              ),
              validator: AppConfig.validateServerUrl,
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
