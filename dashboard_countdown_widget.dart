import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../application/providers/countdown_timer_provider.dart';
import '../../application/providers/clearance_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class DashboardCountdownWidget extends ConsumerWidget {
  const DashboardCountdownWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clearanceAsync = ref.watch(activeClearanceProvider);

    // We only watch the 'finished' state of the timer here to know when to switch UI
    // This flips to true only once, preventing rebuilding the whole parent every second
    final isTimerFinished = ref.watch(
      formattedCountdownProvider.select((val) => val == '00 : 00 : 00'),
    );

    return clearanceAsync.when(
      data: (clearance) {
        if (clearance == null) {
          return const SizedBox.shrink();
        }

        final isFinished = clearance.isFinished;
        final status = clearance.status.toLowerCase();
        final isFailed = status == 'failed';
        final isProcessing = status == 'processing';

        // Show status card if finished, failed, or processing is delayed (timer hit zero)
        final showStatusCard =
            isFinished || isFailed || (isProcessing && isTimerFinished);

        Color statusColor = AppTheme.accentColor;
        if (isFinished) statusColor = Colors.green;
        if (isFailed) statusColor = AppTheme.errorColor;
        if (!isFinished && !isFailed && isTimerFinished) {
          statusColor = Colors.orange;
        }

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: !showStatusCard
                    ? Column(
                        key: const ValueKey('countdown_view'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Your clearance is processing',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Expected completion in',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Optimized Timer Display
                          const CountdownTextWidget(),
                          const SizedBox(height: 32),

                          // Optimized Progress Bar
                          CountdownProgressBarWidget(statusColor: statusColor),
                          const SizedBox(height: 24),

                          // Dynamic Status Line
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Status: ',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const Expanded(
                                child: StatusMessageWidget(isDynamicLine: true),
                              ),
                            ],
                          ),
                        ],
                      )
                    : Column(
                        key: const ValueKey('status_card_view'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Status Card UI
                          Icon(
                            isFinished
                                ? Icons.check_circle_rounded
                                : (isFailed
                                      ? Icons.error_rounded
                                      : Icons.info_rounded),
                            color: statusColor,
                            size: 64,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            isFinished
                                ? 'Clearance Ready!'
                                : (isFailed
                                      ? 'Processing Issue'
                                      : (isTimerFinished
                                            ? 'Processing Delayed'
                                            : 'Status Update')),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Optimized Status Message
                          const StatusMessageWidget(),
                          const SizedBox(height: 32),

                          // Action Buttons
                          if (isFinished)
                            SizedBox(
                              width: double.infinity,
                              child:
                                  (clearance.certificateUrl == null ||
                                      clearance.certificateUrl!.isEmpty)
                                  ? _CertificateWaitingWidget(
                                      reference: clearance.reference,
                                    )
                                  : SizedBox(
                                      height: 56,
                                      child: ElevatedButton.icon(
                                        onPressed: () {
                                          context.push(
                                            AppConstants.pdfViewerRoute,
                                            extra: {
                                              'url': clearance.certificateUrl,
                                              'reference': clearance.reference,
                                            },
                                          );
                                        },
                                        icon: const Icon(
                                          Icons.file_download_rounded,
                                          size: 24,
                                        ),
                                        label: const Text(
                                          'Download Certificate',
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.green,
                                          foregroundColor: Colors.white,
                                          elevation: 8,
                                          shadowColor: Colors.green.withValues(
                                            alpha: 0.4,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                          textStyle: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                    ),
                            )
                          else if (isFailed)
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton.icon(
                                onPressed: () async {
                                  final Uri emailLaunchUri = Uri(
                                    scheme: 'mailto',
                                    path: 'support@infotechsrealm.com',
                                    query: encodeQueryParameters(<
                                      String,
                                      String
                                    >{
                                      'subject':
                                          'Clearance Issue: ${clearance.reference}',
                                      'body':
                                          'Reference: ${clearance.reference}\n\nI need assistance with my clearance application.',
                                    }),
                                  );

                                  try {
                                    if (await canLaunchUrl(emailLaunchUri)) {
                                      await launchUrl(emailLaunchUri);
                                    } else {
                                      throw 'No email client found';
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Error launching email: $e',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(
                                  Icons.support_agent_rounded,
                                  size: 24,
                                ),
                                label: const Text('Contact Support'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.accentColor,
                                  foregroundColor: Colors.white,
                                  elevation: 8,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),

              // Reset Selection Button
              if (ref.watch(selectedClearanceIdProvider) != null) ...[
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: () {
                    ref.read(selectedClearanceIdProvider.notifier).set(null);
                  },
                  icon: const Icon(Icons.history_rounded, size: 20),
                  label: const Text('View Latest Application'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accentColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    backgroundColor: AppTheme.accentColor.withValues(
                      alpha: 0.1,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
      loading: () => Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              'Failed to load timer: $error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  String? encodeQueryParameters(Map<String, String> params) {
    return params.entries
        .map(
          (MapEntry<String, String> e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
  }
}

/// A specialized widget to display the timer text.
/// It only rebuilds when the formatted time changes (every second).
class CountdownTextWidget extends ConsumerWidget {
  const CountdownTextWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // We watch the specific duration value via the timer provider
    // Using select to ensure we only care about the emitted duration
    final duration = ref.watch(
      countdownTimerProvider.select((val) => val.valueOrNull ?? Duration.zero),
    );

    // Formatting logic moved here to keep rebuilds isolated
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    final formatted =
        '${hours.toString().padLeft(2, '0')} : ${minutes.toString().padLeft(2, '0')} : ${seconds.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          formatted,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}

/// A specialized widget to display the progress bar.
/// It only rebuilds when the progress percentage changes.
class CountdownProgressBarWidget extends ConsumerWidget {
  final Color statusColor;
  const CountdownProgressBarWidget({super.key, required this.statusColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      clearanceStatusProvider.select((s) => s.progressPercentage),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LinearProgressIndicator(
        value: progress,
        minHeight: 10,
        backgroundColor: Colors.white.withValues(alpha: 0.1),
        valueColor: AlwaysStoppedAnimation<Color>(statusColor),
      ),
    );
  }
}

/// A specialized widget to display the status message.
/// It only rebuilds when the message text changes.
class StatusMessageWidget extends ConsumerWidget {
  final bool isDynamicLine;
  const StatusMessageWidget({super.key, this.isDynamicLine = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(
      clearanceStatusProvider.select((s) => s.statusMessage),
    );

    if (isDynamicLine) {
      return Text(
        message,
        style: const TextStyle(
          color: AppTheme.accentColor,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        textAlign: TextAlign.center,
      );
    }

    return Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.7),
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// A widget that shows a "Preparing certificate..." spinner and auto-switches
/// to a "Contact Support" fallback after [timeoutDuration] if the certificate
/// URL hasn't been populated by Firestore.
class _CertificateWaitingWidget extends StatefulWidget {
  final String reference;

  const _CertificateWaitingWidget({
    required this.reference,
  });

  @override
  State<_CertificateWaitingWidget> createState() =>
      _CertificateWaitingWidgetState();
}

class _CertificateWaitingWidgetState extends State<_CertificateWaitingWidget> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(minutes: 2), () {
      if (mounted) {
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_timedOut) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(
                color: Colors.green,
                strokeWidth: 3,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Preparing certificate...',
              style: TextStyle(
                color: Colors.green,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    // Timeout reached — show fallback with support option
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Certificate is taking longer than expected.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.orange.shade300,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: () async {
              final Uri emailLaunchUri = Uri(
                scheme: 'mailto',
                path: 'support@infotechsrealm.com',
                query:
                    'subject=${Uri.encodeComponent('Certificate Issue: ${widget.reference}')}'
                    '&body=${Uri.encodeComponent('Reference: ${widget.reference}\n\nMy clearance is completed but the certificate has not been generated.')}',
              );
              try {
                if (await canLaunchUrl(emailLaunchUri)) {
                  await launchUrl(emailLaunchUri);
                }
              } catch (_) {}
            },
            icon: const Icon(Icons.support_agent_rounded, size: 20),
            label: const Text('Contact Support'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
