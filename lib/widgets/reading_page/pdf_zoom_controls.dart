import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/pdf_zoom_state.dart';
import 'package:flutter/material.dart';

class PdfZoomControls extends StatelessWidget {
  const PdfZoomControls({
    super.key,
    required this.state,
    required this.onZoom,
  });

  final PdfZoomState state;
  final ValueChanged<String> onZoom;

  @override
  Widget build(BuildContext context) {
    if (!state.isPdf) return const SizedBox.shrink();
    final l10n = L10n.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: l10n.pdfZoomOut,
          icon: const Icon(Icons.remove),
          onPressed:
              state.ready && state.percent > 50 ? () => onZoom('out') : null,
        ),
        SizedBox(
          width: 56,
          child: Text('${state.percent}%', textAlign: TextAlign.center),
        ),
        IconButton(
          tooltip: l10n.pdfZoomIn,
          icon: const Icon(Icons.add),
          onPressed:
              state.ready && state.percent < 300 ? () => onZoom('in') : null,
        ),
        IconButton(
          tooltip: l10n.pdfZoomReset,
          icon: const Icon(Icons.fit_screen),
          onPressed: state.ready ? () => onZoom('reset') : null,
        ),
        IconButton(
          tooltip: state.panMode ? l10n.pdfSelectText : l10n.pdfDragPage,
          isSelected: state.panMode,
          icon: const Icon(Icons.pan_tool_outlined),
          selectedIcon: const Icon(Icons.pan_tool),
          onPressed: state.ready && state.percent > 100
              ? () => onZoom('togglePan')
              : null,
        ),
      ],
    );
  }
}
