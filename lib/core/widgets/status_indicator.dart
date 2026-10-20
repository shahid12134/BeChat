import 'package:flutter/material.dart';
import 'package:bechat/app/theme/app_theme.dart';

enum TransportStatus { local, mesh, cloud, pending }

class StatusIndicator extends StatelessWidget {
  final TransportStatus status;
  final bool compact;

  const StatusIndicator({super.key, required this.status, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 6 : 8,
          height: compact ? 6 : 8,
          decoration: BoxDecoration(
            color: _color,
            shape: BoxShape.circle,
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 4),
          Text(
            _label,
            style: TextStyle(
              fontSize: 11,
              color: _color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  Color get _color => switch (status) {
    TransportStatus.local => AppColors.online,
    TransportStatus.mesh => AppColors.primary,
    TransportStatus.cloud => AppColors.pending,
    TransportStatus.pending => AppColors.textLight,
  };

  String get _label => switch (status) {
    TransportStatus.local => 'Local',
    TransportStatus.mesh => 'Mesh',
    TransportStatus.cloud => 'Cloud',
    TransportStatus.pending => 'Pending',
  };
}
