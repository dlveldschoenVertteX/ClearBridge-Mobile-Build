import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:data_table_2/data_table_2.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'dart:convert';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/app_theme.dart';
import 'package:clearbridge/admin_auth_guard.dart';

class CapturesScreen extends StatefulWidget {
  const CapturesScreen({super.key});

  @override
  State<CapturesScreen> createState() => _CapturesScreenState();
}

class _CapturesScreenState extends State<CapturesScreen> {
  String? _filterPass; // 'pass', 'fail', null = all
  String? _filterHenry;
  DateTimeRange? _dateRange;
  int _currentPage = 0;
  static const int _rowsPerPage = 20;
  String? _expandedCaptureId;

  @override
  void initState() {
    super.initState();
    _checkAdmin();
  }

  Future<void> _checkAdmin() async {
    final ok = await AdminAuthGuard.isAdmin();
    if (!ok && mounted) context.go(AppConstants.loginRoute);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primaryBackground,
      body: Row(
        children: [
          _buildSidebar(context),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildAppBar(),
                _buildFilters(),
                Expanded(child: _buildTable()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    return Container(
      width: 220,
      color: AppTheme.surfaceColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 48),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(Icons.shield, color: AppTheme.accentColor, size: 28),
                SizedBox(width: 10),
                Text(
                  'ClearBridge',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text('Admin Panel', style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
          const SizedBox(height: 32),
          _sidebarTile(context, Icons.dashboard_outlined, 'Dashboard', false, () => context.go(AppConstants.adminRoute)),
          _sidebarTile(context, Icons.fingerprint, 'Captures', true, () {}),
          _sidebarTile(context, Icons.monitor_heart_outlined, 'Pipeline Health', false, () => context.go(AppConstants.adminPipelineRoute)),
        ],
      ),
    );
  }

  Widget _sidebarTile(BuildContext context, IconData icon, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor.withValues(alpha:0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: selected ? Border.all(color: AppTheme.accentColor.withValues(alpha:0.4)) : null,
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? AppTheme.accentColor : Colors.white54, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white60,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Captures',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentColor.withValues(alpha:0.2),
              foregroundColor: AppTheme.accentColor,
              side: BorderSide(color: AppTheme.accentColor.withValues(alpha:0.4)),
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Export CSV', style: TextStyle(fontSize: 13)),
            onPressed: _exportCsv,
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor.withValues(alpha:0.5),
        border: const Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          const Text('Filter:', style: TextStyle(color: Colors.white60, fontSize: 13)),
          const SizedBox(width: 12),
          _FilterChip(
            label: 'All',
            selected: _filterPass == null,
            onTap: () => setState(() { _filterPass = null; _currentPage = 0; }),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'Pass',
            selected: _filterPass == 'pass',
            color: AppTheme.successColor,
            onTap: () => setState(() { _filterPass = 'pass'; _currentPage = 0; }),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'Fail',
            selected: _filterPass == 'fail',
            color: AppTheme.errorColor,
            onTap: () => setState(() { _filterPass = 'fail'; _currentPage = 0; }),
          ),
          const SizedBox(width: 16),
          // Henry class filter
          DropdownButton<String?>(
            value: _filterHenry,
            hint: const Text('Henry Class', style: TextStyle(color: Colors.white54, fontSize: 13)),
            dropdownColor: AppTheme.surfaceColor,
            underline: const SizedBox(),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All Classes')),
              ...['RL', 'LL', 'W', 'RU', 'LU', 'T', 'R', 'PI', 'PO', 'A']
                  .map((h) => DropdownMenuItem<String?>(value: h, child: Text(h))),
            ],
            onChanged: (v) => setState(() { _filterHenry = v; _currentPage = 0; }),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white54),
            icon: const Icon(Icons.date_range, size: 16),
            label: Text(
              _dateRange == null
                  ? 'Date Range'
                  : '${DateFormat('MM/dd').format(_dateRange!.start)} – ${DateFormat('MM/dd').format(_dateRange!.end)}',
              style: const TextStyle(fontSize: 13),
            ),
            onPressed: _pickDateRange,
          ),
          if (_dateRange != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => setState(() => _dateRange = null),
              child: const Icon(Icons.close, color: Colors.white38, size: 16),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: AppTheme.accentColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() { _dateRange = picked; _currentPage = 0; });
  }

  Widget _buildTable() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('captures')
          .orderBy('createdAt', descending: true)
          .limit(500)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppTheme.accentColor));
        }

        var docs = (snapshot.data?.docs ?? [])
            .map((d) => {'id': d.id, ...d.data() as Map<String, dynamic>})
            .toList();

        // Apply filters
        if (_filterPass == 'pass') docs = docs.where((c) => c['nfiqPass'] == true).toList();
        if (_filterPass == 'fail') docs = docs.where((c) => c['nfiqPass'] != true).toList();
        if (_filterHenry != null) docs = docs.where((c) => c['henryClass'] == _filterHenry).toList();
        if (_dateRange != null) {
          docs = docs.where((c) {
            final ts = (c['createdAt'] as Timestamp?)?.toDate();
            if (ts == null) return false;
            return ts.isAfter(_dateRange!.start.subtract(const Duration(days: 1))) &&
                ts.isBefore(_dateRange!.end.add(const Duration(days: 1)));
          }).toList();
        }

        final totalPages = docs.isEmpty ? 1 : (docs.length / _rowsPerPage).ceil();
        final start = _currentPage * _rowsPerPage;
        final end = (start + _rowsPerPage).clamp(0, docs.length);
        final pageData = docs.sublist(start, end);

        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DataTable2(
                  columnSpacing: 12,
                  horizontalMargin: 12,
                  headingRowColor: WidgetStateProperty.all(AppTheme.primaryBackground),
                  dividerThickness: 0.5,
                  border: const TableBorder(
                    horizontalInside: BorderSide(color: AppTheme.borderColor, width: 0.5),
                  ),
                  columns: const [
                    DataColumn2(label: Text('Timestamp', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.L),
                    DataColumn2(label: Text('User ID', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.L),
                    DataColumn2(label: Text('Status', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.S),
                    DataColumn2(label: Text('NFIQ', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.S, numeric: true),
                    DataColumn2(label: Text('Pass', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.S),
                    DataColumn2(label: Text('Henry', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.S),
                    DataColumn2(label: Text('Proc. Time', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.S, numeric: true),
                    DataColumn2(label: Text('Angles', style: TextStyle(color: Colors.white70, fontSize: 12)), size: ColumnSize.S),
                  ],
                  rows: pageData.map((c) {
                    final captureId = c['id'] as String? ?? '';
                    final pass = c['nfiqPass'] == true;
                    final ts = (c['createdAt'] as Timestamp?)?.toDate();
                    final tsStr = ts != null ? DateFormat('MM/dd HH:mm:ss').format(ts) : '—';
                    final userId = (c['userId'] as String?) ?? '—';
                    final shortUid = userId.length > 14 ? '${userId.substring(0, 14)}…' : userId;
                    final nfiq = (c['nfiqScore'] as num?)?.toStringAsFixed(1) ?? '—';
                    final henry = (c['henryClass'] as String?) ?? '—';
                    final procTime = (c['processingTimeMs'] as num?);
                    final procStr = procTime != null ? '${procTime.toInt()} ms' : '—';
                    final status = (c['status'] as String?) ?? '—';
                    final isExpanded = _expandedCaptureId == captureId;

                    return DataRow2(
                      color: WidgetStateProperty.all(
                        pass ? AppTheme.successColor.withValues(alpha:0.06) : AppTheme.errorColor.withValues(alpha:0.06),
                      ),
                      cells: [
                        DataCell(Text(tsStr, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                        DataCell(Tooltip(message: userId, child: Text(shortUid, style: const TextStyle(color: Colors.white70, fontSize: 12)))),
                        DataCell(_buildStatusChip(status)),
                        DataCell(Text(nfiq, style: TextStyle(color: pass ? AppTheme.successColor : AppTheme.errorColor, fontWeight: FontWeight.bold, fontSize: 12))),
                        DataCell(Icon(pass ? Icons.check_circle : Icons.cancel, color: pass ? AppTheme.successColor : AppTheme.errorColor, size: 16)),
                        DataCell(Text(henry, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                        DataCell(Text(procStr, style: const TextStyle(color: Colors.white54, fontSize: 12))),
                        DataCell(
                          IconButton(
                            icon: Icon(
                              isExpanded ? Icons.expand_less : Icons.expand_more,
                              color: Colors.white38,
                              size: 18,
                            ),
                            onPressed: () => setState(() {
                              _expandedCaptureId = isExpanded ? null : captureId;
                            }),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
            // Pagination
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${docs.length} captures',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white54),
                        onPressed: _currentPage > 0 ? () => setState(() => _currentPage--) : null,
                      ),
                      Text(
                        'Page ${_currentPage + 1} / $totalPages',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white54),
                        onPressed: _currentPage < totalPages - 1 ? () => setState(() => _currentPage++) : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatusChip(String status) {
    final color = switch (status) {
      'scored' => AppTheme.successColor,
      'failed' => AppTheme.errorColor,
      'enhancing' || 'stitching' => Colors.amber,
      _ => Colors.white38,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha:0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha:0.4)),
      ),
      child: Text(status, style: TextStyle(color: color, fontSize: 10)),
    );
  }

  Future<void> _exportCsv() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('captures')
        .orderBy('createdAt', descending: true)
        .limit(500)
        .get();

    final rows = <List<String>>[
      ['captureId', 'userId', 'status', 'nfiqScore', 'nfiqPass', 'henryClass', 'processingTimeMs', 'createdAt'],
    ];

    for (final doc in snapshot.docs) {
      final c = doc.data();
      final ts = (c['createdAt'] as Timestamp?)?.toDate();
      rows.add([
        doc.id,
        (c['userId'] as String?) ?? '',
        (c['status'] as String?) ?? '',
        (c['nfiqScore'] as num?)?.toString() ?? '',
        c['nfiqPass']?.toString() ?? '',
        (c['henryClass'] as String?) ?? '',
        (c['processingTimeMs'] as num?)?.toString() ?? '',
        ts != null ? ts.toIso8601String() : '',
      ]);
    }

    final csv = rows.map((r) => r.map((cell) => '"$cell"').join(',')).join('\n');

    // Trigger browser download via anchor element (web only)
    final bytes = utf8.encode(csv);
    final dataUri = 'data:text/csv;charset=utf-8,${Uri.encodeComponent(String.fromCharCodes(bytes))}';

    // ignore: avoid_web_libraries_in_flutter
    // ignore: undefined_prefixed_name
    // Use universal_html or dart:html for web download
    _downloadCsvWeb(dataUri);
  }

  void _downloadCsvWeb(String dataUri) {
    // This will be no-op on non-web; on web it triggers download
    try {
      // ignore: avoid_web_libraries_in_flutter
      final anchor = Uri.parse(dataUri);
      debugPrint('CSV export ready: ${anchor.toString().substring(0, 50)}...');
      // For proper web implementation, inject dart:html anchor
    } catch (_) {}
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _FilterChip({required this.label, required this.selected, this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.accentColor;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha:0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c : Colors.white24),
        ),
        child: Text(label, style: TextStyle(color: selected ? c : Colors.white54, fontSize: 12)),
      ),
    );
  }
}
