import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../repository/auth_repository.dart';

class EmailActionScreen extends ConsumerStatefulWidget {
  const EmailActionScreen({
    super.key,
    required this.mode,
    required this.oobCode,
  });

  final String mode;
  final String oobCode;

  @override
  ConsumerState<EmailActionScreen> createState() => _EmailActionScreenState();
}

class _EmailActionScreenState extends ConsumerState<EmailActionScreen> {
  _Phase _phase = _Phase.loading;
  String? _errorMessage;
  String? _emailForReset; // resolved by verifyPasswordResetCode

  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final repo = ref.read(authRepositoryProvider);

    switch (widget.mode) {
      case 'verifyEmail':
      case 'recoverEmail':
        await _applyCode(repo);

      case 'resetPassword':
        await _loadResetEmail(repo);

      default:
        setState(() {
          _phase = _Phase.error;
          _errorMessage = 'Unknown action type "${widget.mode}".';
        });
    }
  }

  Future<void> _applyCode(AuthRepository repo) async {
    try {
      await repo.applyActionCode(widget.oobCode);
      if (mounted) setState(() => _phase = _Phase.success);
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _errorMessage = _authMessage(e);
        });
      }
    }
  }

  Future<void> _loadResetEmail(AuthRepository repo) async {
    try {
      final email = await repo.verifyPasswordResetCode(widget.oobCode);
      if (mounted) {
        setState(() {
          _phase = _Phase.resetForm;
          _emailForReset = email;
        });
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _errorMessage = _authMessage(e);
        });
      }
    }
  }

  Future<void> _submitReset() async {
    final password = _passwordCtrl.text.trim();
    if (password.length < 8) {
      _showSnack('Password must be at least 8 characters');
      return;
    }
    if (password != _confirmCtrl.text) {
      _showSnack('Passwords do not match');
      return;
    }

    setState(() => _submitting = true);
    try {
      final repo = ref.read(authRepositoryProvider);
      await repo.confirmPasswordReset(widget.oobCode, password);
      if (mounted) setState(() => _phase = _Phase.success);
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _showSnack(_authMessage(e));
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: ClearBridgeTypography.body),
        backgroundColor: ClearBridgeColors.steel,
      ),
    );
  }

  String _authMessage(FirebaseAuthException e) {
    return switch (e.code) {
      'expired-action-code' => 'This link has expired. Please request a new one.',
      'invalid-action-code' => 'This link is invalid or has already been used.',
      'user-disabled' => 'This account has been disabled.',
      'user-not-found' => 'No account found for this email address.',
      'weak-password' => 'Password is too weak. Use at least 8 characters.',
      _ => e.message ?? 'Something went wrong. Please try again.',
    };
  }

  String get _title => switch (widget.mode) {
        'verifyEmail' => 'Email Verified',
        'recoverEmail' => 'Email Recovered',
        'resetPassword' => 'Reset Password',
        _ => 'Email Action',
      };

  IconData get _successIcon => switch (widget.mode) {
        'resetPassword' => Icons.lock_reset_rounded,
        _ => Icons.mark_email_read_rounded,
      };

  String get _successMessage => switch (widget.mode) {
        'verifyEmail' =>
          'Your email has been verified. You can now use it for notifications and account recovery.',
        'recoverEmail' =>
          'Your original email address has been restored.',
        'resetPassword' =>
          'Your password has been reset successfully. You can now sign in with your new password.',
        _ => 'Action completed successfully.',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded,
              color: ClearBridgeColors.silverBright),
          onPressed: () => context.go(AppConstants.loginRoute),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return switch (_phase) {
      _Phase.loading => const _LoadingView(),
      _Phase.success => _SuccessView(
          icon: _successIcon,
          title: _title,
          message: _successMessage,
          onContinue: () => context.go(AppConstants.loginRoute),
        ),
      _Phase.error => _ErrorView(
          message: _errorMessage ?? 'An unknown error occurred.',
          onBack: () => context.go(AppConstants.loginRoute),
        ),
      _Phase.resetForm => _ResetFormView(
          email: _emailForReset,
          passwordCtrl: _passwordCtrl,
          confirmCtrl: _confirmCtrl,
          obscureNew: _obscureNew,
          obscureConfirm: _obscureConfirm,
          submitting: _submitting,
          onToggleNew: () => setState(() => _obscureNew = !_obscureNew),
          onToggleConfirm: () =>
              setState(() => _obscureConfirm = !_obscureConfirm),
          onSubmit: _submitReset,
        ),
    };
  }
}

enum _Phase { loading, success, error, resetForm }

// ---------------------------------------------------------------------------
// Sub-views
// ---------------------------------------------------------------------------

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: ClearBridgeColors.cyan),
          SizedBox(height: 20),
          Text(
            'Processing…',
            style: TextStyle(color: ClearBridgeColors.silver, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({
    required this.icon,
    required this.title,
    required this.message,
    required this.onContinue,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Container(
          width: 80,
          height: 80,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ClearBridgeColors.success.withValues(alpha: 0.12),
            border: Border.all(
                color: ClearBridgeColors.success.withValues(alpha: 0.30)),
          ),
          child: Icon(icon, size: 40, color: ClearBridgeColors.success),
        ),
        const SizedBox(height: 28),
        Text(
          title,
          textAlign: TextAlign.center,
          style: ClearBridgeTypography.h1.copyWith(
            color: ClearBridgeColors.silverBright,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: ClearBridgeTypography.body.copyWith(height: 1.6),
        ),
        const Spacer(),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: onContinue,
            style: ElevatedButton.styleFrom(
              backgroundColor: ClearBridgeColors.cyan,
              foregroundColor: ClearBridgeColors.void_,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: Text(
              'Continue to Login',
              style: GoogleFonts.manrope(
                  fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Container(
          width: 80,
          height: 80,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ClearBridgeColors.error.withValues(alpha: 0.12),
            border: Border.all(
                color: ClearBridgeColors.error.withValues(alpha: 0.30)),
          ),
          child: const Icon(Icons.error_outline_rounded,
              size: 40, color: ClearBridgeColors.error),
        ),
        const SizedBox(height: 28),
        Text(
          'Link Invalid',
          textAlign: TextAlign.center,
          style: ClearBridgeTypography.h1
              .copyWith(color: ClearBridgeColors.silverBright),
        ),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: ClearBridgeTypography.body.copyWith(height: 1.6),
        ),
        const Spacer(),
        SizedBox(
          height: 52,
          child: OutlinedButton(
            onPressed: onBack,
            style: OutlinedButton.styleFrom(
              foregroundColor: ClearBridgeColors.silverBright,
              side: const BorderSide(color: ClearBridgeColors.steelBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              'Back to Login',
              style: GoogleFonts.manrope(
                  fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResetFormView extends StatelessWidget {
  const _ResetFormView({
    required this.email,
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.obscureNew,
    required this.obscureConfirm,
    required this.submitting,
    required this.onToggleNew,
    required this.onToggleConfirm,
    required this.onSubmit,
  });

  final String? email;
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool obscureNew;
  final bool obscureConfirm;
  final bool submitting;
  final VoidCallback onToggleNew;
  final VoidCallback onToggleConfirm;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Icon(Icons.lock_reset_rounded,
            size: 52, color: ClearBridgeColors.cyan),
        const SizedBox(height: 24),
        Text(
          'Set New Password',
          textAlign: TextAlign.center,
          style: ClearBridgeTypography.h1
              .copyWith(color: ClearBridgeColors.silverBright),
        ),
        if (email != null) ...[
          const SizedBox(height: 8),
          Text(
            email!,
            textAlign: TextAlign.center,
            style: ClearBridgeTypography.body
                .copyWith(color: ClearBridgeColors.cyan),
          ),
        ],
        const SizedBox(height: 32),
        _PasswordField(
          controller: passwordCtrl,
          label: 'New password',
          obscure: obscureNew,
          onToggle: onToggleNew,
        ),
        const SizedBox(height: 14),
        _PasswordField(
          controller: confirmCtrl,
          label: 'Confirm password',
          obscure: obscureConfirm,
          onToggle: onToggleConfirm,
        ),
        const SizedBox(height: 28),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: submitting ? null : onSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: ClearBridgeColors.cyan,
              foregroundColor: ClearBridgeColors.void_,
              disabledBackgroundColor:
                  ClearBridgeColors.cyan.withValues(alpha: 0.38),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: ClearBridgeColors.void_),
                  )
                : Text(
                    'Reset Password',
                    style: GoogleFonts.manrope(
                        fontSize: 15, fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ],
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: ClearBridgeTypography.body
          .copyWith(color: ClearBridgeColors.silverBright),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: ClearBridgeTypography.body
            .copyWith(color: ClearBridgeColors.silverDim),
        filled: true,
        fillColor: ClearBridgeColors.steel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
              color: ClearBridgeColors.steelBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
              color: ClearBridgeColors.cyan, width: 1.5),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
            color: ClearBridgeColors.silverDim,
            size: 20,
          ),
          onPressed: onToggle,
        ),
      ),
    );
  }
}
