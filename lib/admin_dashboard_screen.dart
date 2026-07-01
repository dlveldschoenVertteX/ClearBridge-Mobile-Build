import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:clearbridge/admin_auth_guard.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  static const _bg      = Color(0xFF0B1120);
  static const _surface = Color(0xFF0F2044);
  static const _accent  = Color(0xFF00BFFF);
  static const _green   = Color(0xFF22C55E);
  static const _orange  = Color(0xFFF97316);
  static const _red     = Color(0xFFEF4444);
  static const _subtle  = Color(0xFF1E3A5F);

  int    _selectedIndex = 0;
  String _userEmail = '';

  @override
  void initState() {
    super.initState();
    _userEmail = FirebaseAuth.instance.currentUser?.email ?? '';
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
                Text(
                  'ClearBridge',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
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
                    Text(
                      label,
                      style: TextStyle(
                        color: selected ? _accent : Colors.white60,
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
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
                  _userEmail,
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
        final stats = _computeStats(docs);
        final passRate  = stats['passRate']  as double;
        final avgNfiq   = stats['avgNfiq']   as double;
        final henryDist = stats['henryDist'] as Map<String, int>;
        final statusDist = stats['statusDist'] as Map<String, int>;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Dashboard',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
              Row(
                children: [
                  Expanded(child: _kpiCard(
                    'Total Captures', '${stats['total']}',
                    Icons.photo_camera_outlined, _accent, null,
                  )),
                  const SizedBox(width: 16),
                  Expanded(child: _kpiCard(
                    'Pass Rate', '${passRate.toStringAsFixed(1)}%',
                    Icons.check_circle_outline,
                    passRate >= 80 ? _green : passRate >= 70 ? _orange : _red,
                    '${stats['passed']} passed / ${stats['total']} total',
                  )),
                  const SizedBox(width: 16),
                  Expanded(child: _kpiCard(
                    'Avg NFIQ Score', avgNfiq.toStringAsFixed(1),
                    Icons.analytics_outlined, Colors.white70, null,
                  )),
                  const SizedBox(width: 16),
                  Expanded(child: _kpiCard(
                    'Failed (24h)', '${stats['failed']}',
                    Icons.error_outline, _red, null,
                  )),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildPassRateCard(passRate)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildHenryChart(henryDist)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildPipelineStatus(statusDist)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Map<String, dynamic> _computeStats(List<QueryDocumentSnapshot> docs) {
    int passed = 0, failed = 0;
    double totalNfiq = 0;
    int nfiqCount = 0;
    final henryDist  = <String, int>{};
    final statusDist = <String, int>{};
    for (final doc in docs) {
      final d = doc.data() as Map<String, dynamic>;
      if (d['nfiqPass'] == true) passed++;
      if (d['status'] == 'failed') failed++;
      if (d['nfiqScore'] != null) {
        totalNfiq += (d['nfiqScore'] as num).toDouble();
        nfiqCount++;
      }
      final hc = d['henryClass'] as String? ?? 'Unknown';
      henryDist[hc] = (henryDist[hc] ?? 0) + 1;
      final st = d['status'] as String? ?? 'pending';
      statusDist[st] = (statusDist[st] ?? 0) + 1;
    }
    return {
      'total':     docs.length,
      'passed':    passed,
      'failed':    failed,
      'passRate':  docs.isEmpty ? 0.0 : (passed / docs.length) * 100,
      'avgNfiq':   nfiqCount == 0 ? 0.0 : totalNfiq / nfiqCount,
      'henryDist': henryDist,
      'statusDist': statusDist,
    };
  }

  Widget _kpiCard(String label, String value, IconData icon, Color col, String? sub) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: col.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: col, size: 18),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 12),
          Text(value,
              style: TextStyle(
                  color: col, fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(sub,
                style: const TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _buildPassRateCard(double passRate) {
    final col = passRate >= 80 ? _green : passRate >= 70 ? _orange : _red;
    final label = passRate >= 80 ? 'Excellent' : passRate >= 70 ? 'Acceptable' : 'Needs Attention';
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
          const Text('Pass Rate',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: CircularProgressIndicator(
                    value: (passRate / 100).clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(col),
                    strokeWidth: 8,
                  ),
                ),
                Text(
                  '${passRate.toStringAsFixed(1)}%',
                  style: TextStyle(
                      color: col, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(label,
                style: TextStyle(color: col, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildHenryChart(Map<String, int> henryDist) {
    const colors = [
      _accent, _green, _orange, _red,
      Colors.purple, Colors.yellow, Colors.teal,
      Colors.pink, Colors.indigo, Colors.lime,
    ];
    final entries = henryDist.entries.toList();
    final total = entries.fold<int>(0, (s, e) => s + e.value);
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
          const Text('Henry Classification',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          if (entries.isEmpty)
            const Text('No data yet',
                style: TextStyle(color: Colors.white38, fontSize: 12))
          else
            SizedBox(
              height: 120,
              child: PieChart(
                PieChartData(
                  sections: entries.asMap().entries.map((e) {
                    final col = colors[e.key % colors.length];
                    return PieChartSectionData(
                      value: e.value.value.toDouble(),
                      color: col,
                      title: e.value.key,
                      radius: 50,
                      titleStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold),
                    );
                  }).toList(),
                  sectionsSpace: 2,
                  centerSpaceRadius: 28,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text('$total captures total',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildPipelineStatus(Map<String, int> statusDist) {
    const statusColors = {
      'scored':    _green,
      'enhancing': _accent,
      'stitching': _orange,
      'pending':   Colors.white54,
      'failed':    _red,
    };
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
          const Text('Pipeline Status',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          ...statusColors.entries.map((e) {
            final count = statusDist[e.key] ?? 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                      color: e.value, shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.key[0].toUpperCase() + e.key.substring(1),
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ),
                  Text('$count',
                      style: TextStyle(
                          color: e.value,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
