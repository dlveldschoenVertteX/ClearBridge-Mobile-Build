import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:clearbridge/admin_auth_guard.dart';

class PipelineHealthScreen extends StatefulWidget {
  const PipelineHealthScreen({super.key});

  @override
  State<PipelineHealthScreen> createState() => _PipelineHealthScreenState();
}

class _PipelineHealthScreenState extends State<PipelineHealthScreen> {
  static const _bg      = Color(0xFF0B1120);
  static const _surface = Color(0xFF0F2044);
  static const _accent  = Color(0xFF00BFFF);
  static const _green   = Color(0xFF22C55E);
  static const _orange  = Color(0xFFF97316);
  static const _red     = Color(0xFFEF4444);
  static const _subtle  = Color(0xFF1E3A5F);

  int _selectedIndex = 2;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) context.go('/admin/login');
      return;
    }
    final isAdmin = await AdminAuthGuard.isAdmin();
    if (!isAdmin && mounted) {
      context.go('/admin/login');
    }
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
    if (mounted) context.go('/admin/login');
  }

  DateTime get twentyFourHoursAgo => DateTime.now().subtract(const Duration(hours: 24));

  Stream<QuerySnapshot> get _capturesStream => FirebaseFirestore.instance
      .collection('captures')
      .where('createdAt', isGreaterThan: Timestamp.fromDate(twentyFourHoursAgo))
      .snapshots();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(child: _buildMainContent()),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final items = [
      (Icons.dashboard_outlined,     'Dashboard', '/admin'),
      (Icons.table_rows_outlined,    'Captures',  '/admin/captures'),
      (Icons.monitor_heart_outlined, 'Pipeline',  '/admin/pipeline'),
    ];
    return Container(
      width: 220,
      color: _surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _subtle)),
            ),
            child: const Row(
              children: [
                Icon(Icons.fingerprint, color: _accent, size: 24),
                SizedBox(width: 10),
                Text('ClearBridge',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ...items.asMap().entries.map((e) {
            final i = e.key;
            final (icon, label, route) = e.value;
            final selected = _selectedIndex == i;
            return InkWell(
              onTap: () {
                setState(() => _selectedIndex = i);
                context.go(route);
              },
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? _accent.withValues(alpha: 0.15) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? _accent.withValues(alpha: 0.4) : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(icon, color: selected ? _accent : Colors.white54, size: 18),
                    const SizedBox(width: 10),
                    Text(label,
                        style: TextStyle(
                          color: selected ? _accent : Colors.white60,
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        )),
                  ],
                ),
              ),
            );
          }),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _subtle)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  FirebaseAuth.instance.currentUser?.email ?? '',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _signOut,
                  child: const Row(
                    children: [
                      Icon(Icons.logout, color: Colors.white38, size: 14),
                      SizedBox(width: 6),
                      Text('Sign Out',
                          style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return StreamBuilder<QuerySnapshot>(
      stream: _capturesStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: _accent));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: _red)),
          );
        }
        final docs = snapshot.data?.docs ?? [];
        final metrics = _computeMetrics(docs);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Pipeline Health',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _accent.withValues(alpha: 0.3)),
                    ),
                    child: const Text('● Live',
                        style: TextStyle(color: _accent, fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text('Last 24 hours',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              const SizedBox(height: 24),
              _buildSectionCard(
                'NFIQ Score Distribution',
                _buildNfiqHistogram(metrics['nfiqBuckets'] as List<int>),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildSectionCard(
                    'Processing Time (ms)',
                    _buildProcessingTimeStats(
                        metrics['processingStats'] as Map<String, double>),
                  )),
                  const SizedBox(width: 16),
                  Expanded(child: _buildSectionCard(
                    'Henry Class Pass Rates',
                    _buildHenryPassRates(
                        metrics['henryPassRates'] as Map<String, Map<String, int>>),
                  )),
                ],
              ),
              const SizedBox(height: 16),
              _buildSectionCard(
                'Error Breakdown',
                _buildErrorTable(metrics['errorReasons'] as Map<String, int>),
              ),
            ],
          ),
        );
      },
    );
  }

  Map<String, dynamic> _computeMetrics(List<QueryDocumentSnapshot> docs) {
    final nfiqBuckets = List<int>.filled(5, 0);
    final processingTimes = <double>[];
    final henryPassRates = <String, Map<String, int>>{};
    final errorReasons = <String, int>{};

    for (final doc in docs) {
      final d = doc.data() as Map<String, dynamic>;

      final nfiq = (d['nfiqScore'] as num?)?.toDouble();
      if (nfiq != null) {
        final bucket = (nfiq / 20).floor().clamp(0, 4);
        nfiqBuckets[bucket]++;
      }

      final pt = (d['processingTimeMs'] as num?)?.toDouble();
      if (pt != null) processingTimes.add(pt);

      final hc = d['henryClass'] as String? ?? 'Unknown';
      henryPassRates.putIfAbsent(hc, () => {'passed': 0, 'total': 0});
      henryPassRates[hc]!['total'] = henryPassRates[hc]!['total']! + 1;
      if (d['nfiqPass'] == true) {
        henryPassRates[hc]!['passed'] = henryPassRates[hc]!['passed']! + 1;
      }

      if (d['status'] == 'failed') {
        final reason = d['failureReason'] as String? ?? 'Unknown';
        errorReasons[reason] = (errorReasons[reason] ?? 0) + 1;
      }
    }

    processingTimes.sort();
    final ptStats = <String, double>{
      'min': processingTimes.isEmpty ? 0 : processingTimes.first,
      'max': processingTimes.isEmpty ? 0 : processingTimes.last,
      'avg': processingTimes.isEmpty
          ? 0
          : processingTimes.reduce((a, b) => a + b) / processingTimes.length,
      'p50': processingTimes.isEmpty
          ? 0
          : processingTimes[
              (processingTimes.length * 0.5).floor().clamp(0, processingTimes.length - 1)],
      'p95': processingTimes.isEmpty
          ? 0
          : processingTimes[
              (processingTimes.length * 0.95).floor().clamp(0, processingTimes.length - 1)],
    };

    return {
      'nfiqBuckets':     nfiqBuckets,
      'processingStats': ptStats,
      'henryPassRates':  henryPassRates,
      'errorReasons':    errorReasons,
    };
  }

  Widget _buildSectionCard(String title, Widget child) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _subtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildNfiqHistogram(List<int> buckets) {
    final labels = ['0-20', '20-40', '40-60', '60-80', '80-100'];
    final maxVal = buckets.reduce((a, b) => a > b ? a : b).toDouble();
    return SizedBox(
      height: 160,
      child: BarChart(
        BarChartData(
          maxY: maxVal == 0 ? 10 : maxVal * 1.2,
          barGroups: buckets.asMap().entries.map((e) {
            final isPass = e.key >= 3;
            return BarChartGroupData(
              x: e.key,
              barRods: [
                BarChartRodData(
                  toY: e.value.toDouble(),
                  color: isPass ? _green : _orange,
                  width: 28,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            );
          }).toList(),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (val, _) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(labels[val.toInt()],
                      style: const TextStyle(color: Colors.white38, fontSize: 9)),
                ),
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (val, _) => Text(
                  val.toInt().toString(),
                  style: const TextStyle(color: Colors.white38, fontSize: 9),
                ),
              ),
            ),
            topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: Color(0xFF1E3A5F), strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  Widget _buildProcessingTimeStats(Map<String, double> stats) {
    final rows = [
      ('Min', stats['min']!),
      ('Avg', stats['avg']!),
      ('p50', stats['p50']!),
      ('p95', stats['p95']!),
      ('Max', stats['max']!),
    ];
    return Column(
      children: rows.map((r) {
        final (label, val) = r;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              Text('${val.toStringAsFixed(0)} ms',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHenryPassRates(Map<String, Map<String, int>> henryPassRates) {
    if (henryPassRates.isEmpty) {
      return const Text('No data yet',
          style: TextStyle(color: Colors.white38, fontSize: 12));
    }
    return Column(
      children: henryPassRates.entries.map((e) {
        final passed = e.value['passed']!;
        final total  = e.value['total']!;
        final rate   = total == 0 ? 0.0 : (passed / total) * 100;
        final col    = rate >= 80 ? _green : rate >= 60 ? _orange : _red;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(e.key,
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: LinearProgressIndicator(
                  value: (rate / 100).clamp(0.0, 1.0),
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(col),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 42,
                child: Text('${rate.toStringAsFixed(0)}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: col, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildErrorTable(Map<String, int> errorReasons) {
    if (errorReasons.isEmpty) {
      return const Row(
        children: [
          Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 16),
          SizedBox(width: 8),
          Text('No errors in the last 24h',
              style: TextStyle(color: Color(0xFF22C55E), fontSize: 12)),
        ],
      );
    }
    final sorted = errorReasons.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      children: [
        const Row(
          children: [
            Expanded(child: Text('Reason',
                style: TextStyle(color: Colors.white38, fontSize: 11))),
            Text('Count',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
        const Divider(color: Color(0xFF1E3A5F), height: 12),
        ...sorted.map((e) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Expanded(child: Text(e.key,
                  style: const TextStyle(color: Colors.white60, fontSize: 12))),
              Text('${e.value}',
                  style: const TextStyle(
                      color: Color(0xFFEF4444),
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        )),
      ],
    );
  }
}
