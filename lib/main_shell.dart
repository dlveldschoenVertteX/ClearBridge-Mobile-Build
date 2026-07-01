import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/app_constants.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.
// Wraps the ShellRoute tabs (dashboard/history/profile) registered in
// router_service.dart with a bottom navigation bar.

class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.child});

  final Widget child;

  static const _tabs = [
    (route: AppConstants.dashboardRoute, icon: Icons.dashboard_outlined, label: 'Dashboard'),
    (route: AppConstants.historyRoute, icon: Icons.history, label: 'History'),
    (route: '/profile', icon: Icons.person_outline, label: 'Profile'),
  ];

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final index = _tabs.indexWhere((t) => location.startsWith(t.route));
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final index = _currentIndex(context);
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        backgroundColor: ClearBridgeColors.navy,
        selectedItemColor: ClearBridgeColors.cyan,
        unselectedItemColor: ClearBridgeColors.silverDim,
        type: BottomNavigationBarType.fixed,
        onTap: (i) => context.go(_tabs[i].route),
        items: _tabs
            .map((t) => BottomNavigationBarItem(icon: Icon(t.icon), label: t.label))
            .toList(),
      ),
    );
  }
}
