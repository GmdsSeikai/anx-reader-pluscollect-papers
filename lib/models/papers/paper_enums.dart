/// Status enums for the paper collection module.
///
/// Values are persisted as strings; unknown values fail validation instead
/// of being coerced to a default.
library;

enum PaperChannel {
  latest('latest'),
  hot('hot');

  const PaperChannel(this.code);
  final String code;

  static PaperChannel fromCode(String code) {
    for (final value in PaperChannel.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown paper channel: $code');
  }
}

enum PaperRunTrigger {
  manual('manual'),
  schedule('schedule'),
  recovery('recovery');

  const PaperRunTrigger(this.code);
  final String code;

  static PaperRunTrigger fromCode(String code) {
    for (final value in PaperRunTrigger.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown run trigger: $code');
  }
}

enum PaperRunStatus {
  queued('queued'),
  running('running'),
  succeeded('succeeded'),
  partial('partial'),
  failed('failed'),
  cancelled('cancelled'),
  interrupted('interrupted');

  const PaperRunStatus(this.code);
  final String code;

  static PaperRunStatus fromCode(String code) {
    for (final value in PaperRunStatus.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown run status: $code');
  }
}

enum PaperSliceStatus {
  pending('pending'),
  running('running'),
  completed('completed'),
  failed('failed'),
  interrupted('interrupted');

  const PaperSliceStatus(this.code);
  final String code;

  static PaperSliceStatus fromCode(String code) {
    for (final value in PaperSliceStatus.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown slice status: $code');
  }
}

enum PaperAnalysisStatus {
  pending('pending'),
  running('running'),
  succeeded('succeeded'),
  failed('failed'),
  interrupted('interrupted'),
  blocked('blocked');

  const PaperAnalysisStatus(this.code);
  final String code;

  static PaperAnalysisStatus fromCode(String code) {
    for (final value in PaperAnalysisStatus.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown analysis status: $code');
  }
}

enum PaperImportStatus {
  queued('queued'),
  downloading('downloading'),
  downloaded('downloaded'),
  importing('importing'),
  imported('imported'),
  failed('failed'),
  cancelled('cancelled'),
  interrupted('interrupted');

  const PaperImportStatus(this.code);
  final String code;

  static PaperImportStatus fromCode(String code) {
    for (final value in PaperImportStatus.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown import status: $code');
  }
}

enum PaperMatchBranch {
  topic('topic'),
  author('author'),
  category('category');

  const PaperMatchBranch(this.code);
  final String code;

  static PaperMatchBranch fromCode(String code) {
    for (final value in PaperMatchBranch.values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown match branch: $code');
  }
}
