class PdfZoomState {
  const PdfZoomState({
    this.isPdf = false,
    this.ready = false,
    this.percent = 100,
    this.panMode = false,
  });

  final bool isPdf;
  final bool ready;
  final int percent;
  final bool panMode;

  factory PdfZoomState.fromMap(Map<String, dynamic> value) => PdfZoomState(
        isPdf: value['isPdf'] == true,
        ready: value['ready'] == true,
        percent: (value['percent'] as num).round().clamp(50, 300),
        panMode: value['panMode'] == true,
      );
}
