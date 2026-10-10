import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/providers/paper_list.dart';
import 'package:flutter/material.dart';

/// One candidate row: title, author snippet, first-submission date, topics,
/// relevance, citation count and status chips.
class PaperCandidateTile extends StatelessWidget {
  const PaperCandidateTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onSelectionChanged,
  });

  final PaperListItem item;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool?> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final paper = item.paper;
    final authorSnippet = paper.authors.isEmpty
        ? ''
        : paper.authors.length <= 3
            ? paper.authors.map((a) => a.name).join(', ')
            : '${paper.authors.take(3).map((a) => a.name).join(', ')}, …';

    return ListTile(
      leading: Checkbox(
        value: selected,
        onChanged: onSelectionChanged,
      ),
      title: Text(
        paper.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (authorSnippet.isNotEmpty)
            Text(
              authorSnippet,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                paper.publishedAt.toLocal().toString().split(' ').first,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (paper.categories.isNotEmpty)
                Text(
                  paper.categories.take(2).join(', '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              _chip(
                context,
                item.aiScore != null
                    ? '${l10n.papersRelevance} ${item.aiScore}'
                    : item.assessmentPending
                        ? l10n.papersRelevancePending
                        : '${l10n.papersRelevance} ${item.ruleScore}',
                color: item.lowRelevance
                    ? Colors.orange
                    : Theme.of(context).colorScheme.primary,
              ),
              if (item.citationUnknown)
                _chip(context, l10n.papersCitationsUnknown, color: Colors.grey)
              else
                _chip(
                  context,
                  item.citationCount == 0
                      ? l10n.papersCitationsZero
                      : '${l10n.papersCitations} ${item.citationCount}'
                          '${item.citationStale ? ' *' : ''}',
                  color: item.citationStale ? Colors.orange : Colors.blue,
                ),
              if (item.imported)
                _chip(context, l10n.papersImported, color: Colors.green),
              if (item.authorWatch)
                _chip(context, l10n.papersAuthorsLabel,
                    color: Colors.teal),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _chip(BuildContext context, String text, {required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: color, fontSize: 11),
      ),
    );
  }
}
