import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../result.dart';
import '../theme/app_theme.dart';

/// Shared UI pieces used by more than one feature.

/// Full-screen state that is loading / empty / failed, with one retry action.
///
/// Every remote view in the app routes through this so failure handling looks
/// identical everywhere and so we never ship a screen that silently shows an
/// empty list when the real answer is "the request failed".
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.onRetry,
    required this.builder,
    this.emptyWhen,
    this.emptyTitle,
    this.emptyBody,
  });

  final Result<T> value;
  final VoidCallback onRetry;
  final Widget Function(T data) builder;
  final bool Function(T data)? emptyWhen;
  final String? emptyTitle;
  final String? emptyBody;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return switch (value) {
      Failure(:final failure) => ErrorState(
          failure: failure,
          onRetry: onRetry,
        ),
      Success(:final data) when emptyWhen?.call(data) ?? false => EmptyState(
          title: emptyTitle ?? l10n.emptyTitle,
          body: emptyBody ?? l10n.emptyBody,
          onRetry: onRetry,
        ),
      Success(:final data) => builder(data),
    };
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.onRetry,
    this.icon = Icons.inbox_outlined,
  });

  final String title;
  final String body;
  final VoidCallback? onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.outline),
            const SizedBox(height: AppTheme.spaceMd),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: AppTheme.spaceSm),
            Text(body,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: AppTheme.spaceLg),
              FilledButton.tonal(onPressed: onRetry, child: Text(l10n.retry)),
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.failure, required this.onRetry});

  final Object failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    // `failure` arrives either as a bare AppFailure (from a nested widget) or
    // as a failed Result. Copy it to a local first: a field of static type
    // Object does not promote from an `is` test, a local does.
    final Object target = failure;
    final label = target is AppFailure
        ? l10n.errorFor(target.kind.name)
        : l10n.errUnknown;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: scheme.error),
            const SizedBox(height: AppTheme.spaceMd),
            Text(l10n.errorGenericTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppTheme.spaceSm),
            Text(label,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: AppTheme.spaceLg),
            FilledButton.tonal(onPressed: onRetry, child: Text(l10n.retry)),
          ],
        ),
      ),
    );
  }
}

/// Section heading used across screens for visual consistency.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spaceMd,
          AppTheme.spaceLg,
          AppTheme.spaceMd,
          AppTheme.spaceSm,
        ),
        child: Row(
          children: [
            Expanded(
              child:
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// Card wrapper with consistent padding and radius.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: padding ?? const EdgeInsets.all(AppTheme.spaceMd),
          child: child,
        ),
      );
}

/// Small labelled value pair used in weather detail rows.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: AppTheme.spaceXs),
        Text(value, style: text.labelLarge),
        const SizedBox(height: 2),
        Text(label, style: text.bodySmall),
      ],
    );
  }
}

/// Centred progress indicator, for initial loads where there is no layout to
/// skeleton yet.
class CenterLoader extends StatelessWidget {
  const CenterLoader({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

/// [ValueListenableBuilder] re-export so feature files import one place.
typedef Listen = ValueListenableBuilder;
