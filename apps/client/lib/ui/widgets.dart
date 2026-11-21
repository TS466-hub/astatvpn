import 'package:flutter/material.dart';

import 'theme.dart';

/// Основная кнопка: инвертированная, как на сайте. `ghost` — контурная.
class AstatButton extends StatelessWidget {
  const AstatButton(this.label, {super.key, this.onTap, this.ghost = false, this.small = false, this.loading = false});
  final String label;
  final VoidCallback? onTap;
  final bool ghost;
  final bool small;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null && !loading;
    final fg = ghost ? c.text : c.bg;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled || loading ? 1 : 0.4,
        child: Material(
          color: ghost ? Colors.transparent : c.text,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: ghost ? c.border : c.text)),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(radius),
            child: Container(
              constraints: BoxConstraints(minHeight: small ? 38 : 52),
              padding: EdgeInsets.symmetric(horizontal: small ? 14 : 20, vertical: 8),
              alignment: Alignment.center,
              child: loading
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                  : Text(label, textAlign: TextAlign.center, style: mono(fg, small ? 13 : 14, weight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Блок с тонкой рамкой.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(14)});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
        child: Row(children: [
          Expanded(child: Text(text.toUpperCase(), style: mono(context.c.muted, 11, weight: FontWeight.w700, spacing: 1.4))),
          ?trailing,
        ]),
      );
}

/// Строка настройки с подписью и элементом справа.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, this.subtitle, this.trailing, this.onTap});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: mono(c.text, 14, weight: FontWeight.w500)),
              if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle!, style: mono(c.muted, 12, height: 1.4))),
            ]),
          ),
          if (trailing != null) Padding(padding: const EdgeInsets.only(left: 12), child: trailing!),
        ]),
      ),
    );
  }
}

/// Переключатель в виде `[x]` / `[ ]`.
class Check extends StatelessWidget {
  const Check(this.value, {super.key});
  final bool value;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: value,
        child: Text(value ? '[x]' : '[ ]', style: mono(value ? context.c.text : context.c.muted, 15, weight: FontWeight.w700)),
      );
}

class RowsPanel extends StatelessWidget {
  const RowsPanel({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Panel(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) Divider(color: context.c.border), children[i]],
          ],
        ),
      );
}

void toast(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}

/// Ограничивает ширину содержимого на планшетах и компьютерах.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 24)});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: padding, children: children),
        ),
      );
}

String formatBytes(int bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// «1 день», «2 дня», «5 дней».
String plural(int n, String one, String few, String many) {
  final a = n.abs() % 100, b = a % 10;
  if (a > 10 && a < 20) return '$n $many';
  if (b == 1) return '$n $one';
  if (b >= 2 && b <= 4) return '$n $few';
  return '$n $many';
}
