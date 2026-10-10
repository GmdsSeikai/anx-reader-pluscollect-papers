import 'dart:convert';

class PaperAuthor {
  const PaperAuthor({
    required this.name,
    this.order = 0,
    this.affiliation,
  });

  final String name;

  /// Position in the source author list, 0-based.
  final int order;

  /// Only filled when the source provides it; never inferred from name.
  final String? affiliation;

  static const int jsonVersion = 1;

  factory PaperAuthor.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int? ?? 1;
    if (version != jsonVersion) {
      throw FormatException('Unsupported author version: $version');
    }
    final name = (json['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      throw FormatException('Author requires a name');
    }
    return PaperAuthor(
      name: name,
      order: json['order'] as int? ?? 0,
      affiliation: (json['affiliation'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['affiliation'] as String).trim(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': jsonVersion,
        'name': name,
        'order': order,
        'affiliation': affiliation,
      };
}

/// A discovered arXiv candidate.
///
/// [arxivId] is the stable id without the version suffix; [latestVersion]
/// is the newest version the source reported. `published_at` is the first
/// version submission time and never replaced by `updated_at`.
class Paper {
  Paper({
    required this.arxivId,
    required this.latestVersion,
    required this.title,
    required this.authors,
    required this.abstractText,
    required this.categories,
    required this.publishedAt,
    required this.updatedAt,
    required this.contentHash,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.absUrl,
    this.pdfUrl,
    this.doi,
    this.journalRef,
    this.ignored = false,
  });

  final String arxivId;
  int latestVersion;
  String title;
  List<PaperAuthor> authors;
  String abstractText;
  List<String> categories;
  DateTime publishedAt;
  DateTime updatedAt;
  String? absUrl;
  String? pdfUrl;
  String? doi;
  String? journalRef;
  String contentHash;
  DateTime firstSeenAt;
  DateTime lastSeenAt;
  bool ignored;

  static const int jsonVersion = 1;

  static String contentHashOf({
    required String title,
    required String abstractText,
    required List<PaperAuthor> authors,
    required List<String> categories,
  }) {
    // Deliberately simple and stable; callers compare hashes, never render
    // them. Uses JSON so separators cannot collide between fields.
    final canonical = jsonEncode(<String, dynamic>{
      'title': title,
      'abstract': abstractText,
      'authors': authors.map((a) => a.name).toList(),
      'categories': categories,
    });
    return canonical;
  }

  factory Paper.fromDb(Map<String, dynamic> row) {
    List<PaperAuthor> parseAuthors(String raw) {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw FormatException('authors_json must be a list');
      }
      return decoded
          .map((e) => PaperAuthor.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false);
    }

    List<String> parseCategories(String raw) {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw FormatException('categories_json must be a list');
      }
      return decoded.map((e) => e as String).toList(growable: false);
    }

    return Paper(
      arxivId: row['arxiv_id'] as String,
      latestVersion: row['latest_version'] as int? ?? 1,
      title: row['title'] as String? ?? '',
      authors: parseAuthors(row['authors_json'] as String),
      abstractText: row['abstract'] as String? ?? '',
      categories: parseCategories(row['categories_json'] as String),
      publishedAt: DateTime.parse(row['published_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      absUrl: row['abs_url'] as String?,
      pdfUrl: row['pdf_url'] as String?,
      doi: row['doi'] as String?,
      journalRef: row['journal_ref'] as String?,
      contentHash: row['content_hash'] as String? ?? '',
      firstSeenAt: DateTime.parse(row['first_seen_at'] as String),
      lastSeenAt: DateTime.parse(row['last_seen_at'] as String),
      ignored: (row['ignored'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'arxiv_id': arxivId,
        'latest_version': latestVersion,
        'title': title,
        'authors_json':
            jsonEncode(authors.map((a) => a.toJson()).toList(growable: false)),
        'abstract': abstractText,
        'categories_json': jsonEncode(categories),
        'published_at': publishedAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'abs_url': absUrl,
        'pdf_url': pdfUrl,
        'doi': doi,
        'journal_ref': journalRef,
        'content_hash': contentHash,
        'first_seen_at': firstSeenAt.toUtc().toIso8601String(),
        'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
        'ignored': ignored ? 1 : 0,
      };
}
