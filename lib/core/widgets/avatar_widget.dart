import 'package:flutter/material.dart';
import 'package:bechat/app/theme/app_theme.dart';

class PeerAvatar extends StatelessWidget {
  final String? name;
  final String? avatarPath;
  final double radius;
  final bool isOnline;

  const PeerAvatar({
    super.key,
    this.name,
    this.avatarPath,
    this.radius = 24,
    this.isOnline = false,
  });

  @override
  Widget build(BuildContext context) {
    final initials = _getInitials(name);
    final color = _getColor(name);

    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: color,
          child: Text(
            initials,
            style: TextStyle(
              color: Colors.white,
              fontSize: radius * 0.7,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: radius * 0.5,
              height: radius * 0.5,
              decoration: BoxDecoration(
                color: AppColors.online,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
      ],
    );
  }

  String _getInitials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  Color _getColor(String? name) {
    if (name == null || name.isEmpty) return Colors.grey;
    final colors = [
      const Color(0xFF1A73E8),
      const Color(0xFF34A853),
      const Color(0xFFEA4335),
      const Color(0xFFF9AB00),
      const Color(0xFF9C27B0),
      const Color(0xFF00BCD4),
      const Color(0xFFFF5722),
      const Color(0xFF607D8B),
    ];
    final index = name.hashCode.abs() % colors.length;
    return colors[index];
  }
}
