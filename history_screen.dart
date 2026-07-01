import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../application/providers/clearance_provider.dart';
import '../../application/models/clearance_model.dart';
import '../../application/providers/application_flow_provider.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entryCtrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _fade = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(userClearancesProvider);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
            child: Text('My Clearances', style: ClearBridgeTypography.h2),
          ),
          Expanded(
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(userClearancesProvider);
              await ref
                  .read(userClearancesProvider.future)
                  .catchError((_) => <ClearanceModel>[]);
            },
            color: ClearBridgeColors.cyan,
            backgroundColor: ClearBridgeColors.navy,
            child: historyAsync.when(
              data: (clearances) {
                if (clearances.isEmpty) {
                  return _buildEmptyState(context, ref);
                }

                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                        child: _buildSummaryHeader(clearances)),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final clearance = clearances[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 20),
                              child: HistoryCard(clearance: clearance),
                            );
                          },
                          childCount: clearances.length,
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(
                    color: ClearBridgeColors.cyan),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _buildErrorState(error.toString()),
              ),
            ),
          ),
        ),
      ),
            ),
          ],
        ),
      );
  }

  Widget _buildSummaryHeader(List<ClearanceModel> clearances) {
    final completed = clearances.where((c) => c.isFinished).length;
    final processing = clearances
        .where((c) => !c.isFinished && c.status.toLowerCase() != 'failed')
        .length;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            ClearBridgeColors.cyan.withValues(alpha: 0.15),
            ClearBridgeColors.cyan.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: ClearBridgeColors.cyan.withValues(alpha: 0.2),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Application Summary',
                    style: ClearBridgeTypography.h3,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Track your ongoing requests',
                    style: ClearBridgeTypography.caption,
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ClearBridgeColors.cyan.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.analytics_outlined,
                  color: ClearBridgeColors.cyan,
                  size: 24,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              _buildStatItem(
                'Cleared',
                completed.toString(),
                ClearBridgeColors.success,
              ),
              const SizedBox(width: 16),
              _buildStatItem(
                'Processing',
                processing.toString(),
                ClearBridgeColors.cyan,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: ClearBridgeTypography.h1.copyWith(
                color: color,
                fontSize: 24,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: ClearBridgeTypography.eyebrow,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 80),
            Container(
              height: 280,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.2),
                    blurRadius: 40,
                    spreadRadius: -10,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: Image.asset(
                  'assets/images/history_empty.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 48),
            Text(
              'No Clearances Yet',
              style: ClearBridgeTypography.h1,
            ),
            const SizedBox(height: 16),
            Text(
              'Your historical applications will appear here once you start a request.',
              textAlign: TextAlign.center,
              style: ClearBridgeTypography.body,
            ),
            const SizedBox(height: 48),
            SizedBox(
              width: double.infinity,
              height: 64,
              child: ElevatedButton(
                onPressed: () {
                  ref.read(isFingerprintOnlyProvider.notifier).state = false;
                  context.push(AppConstants.serviceTierRoute);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClearBridgeColors.cyan,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 12,
                  shadowColor: ClearBridgeColors.cyan.withValues(alpha: 0.4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Get Police Clearance',
                      style: ClearBridgeTypography.h3.copyWith(
                        color: Colors.white,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.arrow_forward_rounded),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: ClearBridgeColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                color: ClearBridgeColors.error,
                size: 48,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Unable to Load History',
              style: ClearBridgeTypography.h2,
            ),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: ClearBridgeTypography.body,
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryCard extends ConsumerWidget {
  final ClearanceModel clearance;

  const HistoryCard({super.key, required this.clearance});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFinished = clearance.isFinished;
    final statusLabel = clearance.displayStatus;

    final Color statusColor;
    final IconData statusIcon;

    if (isFinished) {
      statusColor = ClearBridgeColors.success;
      statusIcon = Icons.verified_user_rounded;
    } else if (statusLabel == 'PROCESSING') {
      statusColor = ClearBridgeColors.cyan;
      statusIcon = Icons.rocket_launch_rounded;
    } else if (statusLabel == 'FAILED') {
      statusColor = ClearBridgeColors.error;
      statusIcon = Icons.dangerous_rounded;
    } else {
      statusColor = ClearBridgeColors.silver;
      statusIcon = Icons.hourglass_empty_rounded;
    }

    final targetDate =
        clearance.completedAt ?? clearance.expectedCompletionTime;
    final formattedDate = _formatDate(targetDate);

    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: ClearBridgeColors.cardBorder,
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(statusIcon, color: statusColor, size: 28),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            clearance.reference.toUpperCase(),
                            style: ClearBridgeTypography.h3.copyWith(
                              letterSpacing: 0.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'REF: ${clearance.clearanceId.substring(0, 12).toUpperCase()}',
                            style: ClearBridgeTypography.mono,
                          ),
                        ],
                      ),
                    ),
                    _buildStatusBadge(statusLabel, statusColor),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildInfoCol('TIER', clearance.tier.toUpperCase()),
                      Container(
                          width: 1,
                          height: 30,
                          color: ClearBridgeColors.cardBorder),
                      _buildInfoCol('DATE', formattedDate),
                      Container(
                          width: 1,
                          height: 30,
                          color: ClearBridgeColors.cardBorder),
                      _buildInfoCol(
                        'PRICE',
                        'R${clearance.price.toStringAsFixed(0)}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _buildDynamicActionButton(
                  context,
                  ref,
                  clearance.status,
                  clearance,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: ClearBridgeTypography.label.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildInfoCol(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: ClearBridgeTypography.eyebrow,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: ClearBridgeTypography.body.copyWith(
            color: ClearBridgeColors.silverBright,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  void _openCertificate(BuildContext context, ClearanceModel clearance) {
    if (clearance.certificateUrl == null || clearance.certificateUrl!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your certificate is being prepared. Please try again shortly.',
          ),
        ),
      );
    } else {
      context.push(
        AppConstants.pdfViewerRoute,
        extra: {
          'url': clearance.certificateUrl,
          'reference': clearance.reference,
        },
      );
    }
  }

  Widget _buildDynamicActionButton(
    BuildContext context,
    WidgetRef ref,
    String status,
    ClearanceModel clearanceModel,
  ) {
    final bool isCompleted = clearanceModel.isFinished;
    final String label =
        isCompleted ? 'Download Certificate' : 'Track Progress';
    final IconData icon =
        isCompleted ? Icons.file_download_rounded : Icons.radar_rounded;
    final Color bgColor =
        isCompleted ? ClearBridgeColors.success : ClearBridgeColors.cyan;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: () {
          if (isCompleted) {
            _openCertificate(context, clearanceModel);
          } else {
            ref
                .read(selectedClearanceIdProvider.notifier)
                .set(clearanceModel.clearanceId);
            context.go(AppConstants.dashboardRoute);
          }
        },
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: Colors.white,
          elevation: 6,
          shadowColor: bgColor.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: ClearBridgeTypography.h3.copyWith(
            fontSize: 15,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}
