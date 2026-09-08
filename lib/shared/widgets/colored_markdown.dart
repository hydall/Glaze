import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:url_launcher/url_launcher.dart';

Color? parseHexColor(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 3) h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
  if (h.length == 4) h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}${h[3]}${h[3]}';
  if (h.length == 6) h = 'ff$h';
  if (h.length != 8) return null;
  final value = int.tryParse(h, radix: 16);
  if (value == null) return null;
  return Color(value);
}

class HtmlColorMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==hc:(#[0-9a-fA-F]{3,8})==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final colorHex = match?[1] ?? '#ffffff';
    final content = match?[2] ?? '';
    final color = parseHexColor(colorHex) ?? (config.style?.color ?? Colors.white);
    return TextSpan(
      children: MarkdownComponent.generate(context, content, config.copyWith(
        style: (config.style ?? const TextStyle()).copyWith(color: color),
      ), false),
      style: (config.style ?? const TextStyle()).copyWith(color: color),
    );
  }
}

class GlowTextMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==glow:(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final glowColorHex = match?[1] ?? '#ffffff';
    final blurRadius = int.tryParse(match?[2] ?? '4') ?? 4;
    final content = match?[3] ?? '';
    final glowColor = parseHexColor(glowColorHex) ?? Colors.white;
    final baseStyle = config.style ?? const TextStyle();
    return TextSpan(
      children: MarkdownComponent.generate(context, content, config.copyWith(
        style: baseStyle.copyWith(
          shadows: [
            Shadow(color: glowColor, blurRadius: blurRadius.toDouble()),
            Shadow(color: glowColor, blurRadius: blurRadius.toDouble() * 0.5),
          ],
        ),
      ), false),
      style: baseStyle.copyWith(
        shadows: [
          Shadow(color: glowColor, blurRadius: blurRadius.toDouble()),
          Shadow(color: glowColor, blurRadius: blurRadius.toDouble() * 0.5),
        ],
      ),
    );
  }
}

class ColorGlowTextMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==cg:(#[0-9a-fA-F]{3,8}),(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final textColorHex = match?[1] ?? '#ffffff';
    final glowColorHex = match?[2] ?? '#ffffff';
    final blurRadius = int.tryParse(match?[3] ?? '4') ?? 4;
    final content = match?[4] ?? '';
    final textColor = parseHexColor(textColorHex) ?? Colors.white;
    final glowColor = parseHexColor(glowColorHex) ?? Colors.white;
    final baseStyle = config.style ?? const TextStyle();
    return TextSpan(
      children: MarkdownComponent.generate(context, content, config.copyWith(
        style: baseStyle.copyWith(
          color: textColor,
          shadows: [
            Shadow(color: glowColor, blurRadius: blurRadius.toDouble()),
            Shadow(color: glowColor, blurRadius: blurRadius.toDouble() * 0.5),
          ],
        ),
      ), false),
      style: baseStyle.copyWith(
        color: textColor,
        shadows: [
          Shadow(color: glowColor, blurRadius: blurRadius.toDouble()),
          Shadow(color: glowColor, blurRadius: blurRadius.toDouble() * 0.5),
        ],
      ),
    );
  }
}

class GradientTextMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==grad:(#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+)==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    if (match == null) {
      return TextSpan(text: text, style: config.style);
    }
    final colorsParam = match[1]!;
    final content = match[2]!;

    final colors = RegExp(r'#[0-9a-fA-F]{3,8}')
        .allMatches(colorsParam)
        .map((m) => parseHexColor(m[0]!) ?? Colors.white)
        .toList();

    if (colors.length < 2) {
      final baseStyle = config.style ?? const TextStyle();
      return TextSpan(
        children: MarkdownComponent.generate(context, content, config, false),
        style: baseStyle,
      );
    }

    final baseStyle = config.style ?? const TextStyle();
    final fontSize = baseStyle.fontSize ?? 14;

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: ShaderMask(
        shaderCallback: (bounds) => LinearGradient(
          colors: colors,
        ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
        blendMode: BlendMode.srcIn,
        child: Text(
          content,
          style: baseStyle.copyWith(
            color: Colors.white,
            fontSize: fontSize,
          ),
        ),
      ),
    );
  }
}

class BackgroundTextMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==bg:(#[0-9a-fA-F]{3,8})==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final bgColorHex = match?[1] ?? '#333333';
    final content = match?[2] ?? '';
    final bgColor = parseHexColor(bgColorHex) ?? const Color(0xFF333333);
    final baseStyle = config.style ?? const TextStyle();
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          content,
          style: baseStyle.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

class ColoredItalicMd extends InlineMd {
  final Color? color;
  ColoredItalicMd({this.color});

  @override
  RegExp get exp =>
      RegExp(r"(?:(?<!\*)\*(?<!\s)(.+?)(?<!\s)\*(?!\*))", dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = exp.firstMatch(text.trim());
    var data = match?[1] ?? match?[2];
    var conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        fontStyle: FontStyle.italic,
        color: color ?? config.style?.color,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, "$data", conf, false),
      style: conf.style,
    );
  }
}

class ColoredUnderscoreItalicMd extends InlineMd {
  final Color? color;
  ColoredUnderscoreItalicMd({this.color});

  @override
  RegExp get exp =>
      RegExp(r"(?:(?<!_|\w)_(?<!\s)(.+?)(?<!\s)_(?!_|\w))", dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = exp.firstMatch(text.trim());
    var data = match?[1] ?? match?[2];
    var conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        fontStyle: FontStyle.italic,
        color: color ?? config.style?.color,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, "$data", conf, false),
      style: conf.style,
    );
  }
}

class ColoredBoldMd extends InlineMd {
  final Color? color;
  ColoredBoldMd({this.color});

  @override
  RegExp get exp => RegExp(r"(?<!\*)\*\*(?<!\s)(.+?)(?<!\s)\*\*(?!\*)");

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = exp.firstMatch(text.trim());
    var conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.bold,
        color: color ?? config.style?.color,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, "${match?[1]}", conf, false),
      style: conf.style,
    );
  }
}

class ColoredUnderscoreBoldMd extends InlineMd {
  final Color? color;
  ColoredUnderscoreBoldMd({this.color});

  @override
  RegExp get exp => RegExp(r"(?<!_|\w)__(?<!\s)(.+?)(?<!\s)__(?!_|\w)");

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = exp.firstMatch(text.trim());
    var conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.bold,
        color: color ?? config.style?.color,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, "${match?[1]}", conf, false),
      style: conf.style,
    );
  }
}

/// Inline `[label](url)` link. A custom `inlineComponents` list replaces
/// gpt_markdown's built-in inline parsers (including its link parser), so this
/// restores tappable links. Only `http`/`https` targets are accepted; the
/// label keeps flowing inline (via a [TapGestureRecognizer]) so long links wrap
/// like normal text. When [color] is null the link uses the theme's primary
/// colour.
class LinkMd extends InlineMd {
  final Color? color;
  LinkMd({this.color});

  @override
  RegExp get exp => RegExp(r'\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)');

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text.trim());
    final label = match?[1] ?? '';
    final url = match?[2] ?? '';
    final linkColor = color ?? Theme.of(context).colorScheme.primary;
    final style = (config.style ?? const TextStyle()).copyWith(
      color: linkColor,
      decoration: TextDecoration.underline,
      decorationColor: linkColor,
    );
    return TextSpan(
      text: label,
      style: style,
      recognizer: TapGestureRecognizer()
        ..onTap = () {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
    );
  }
}

/// Inline linked image `[![alt](imgUrl)](linkUrl)` — the shape an HTML
/// `<a href><img></a>` collapses to once `htmlToMarkdown` converts the inner
/// `<img>` before the wrapping `<a>`. gpt_markdown ships no linked-image parser,
/// and [LinkMd] would otherwise greedily eat `[![](img)` (treating the leading
/// `![` as the link label), leaving `](link)` as literal text. So this MUST be
/// listed BEFORE [LinkMd] in `inlineComponents`: with gpt_markdown's combined
/// left-to-right alternation, the earlier entry wins the position-0 match.
///
/// Renders the image through the config's `imageBuilder` (so http/https, data:
/// and local files are handled the same as a plain image) and makes it tappable
/// to open the target URL. Only `http`/`https` link targets are accepted.
class LinkedImageMd extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'\[!\[([^\]]*)\]\(([^\s)]*)\)\]\((https?:\/\/[^\s)]+)\)');

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text.trim());
    if (match == null) return TextSpan(text: text, style: config.style);
    final altText = match[1] ?? '';
    final imageUrl = match[2] ?? '';
    final linkUrl = match[3] ?? '';

    // Optional `WxH` size prefix in the alt text, mirroring gpt_markdown's
    // ImageMd so `![100x200](url)` still sizes the linked image.
    double? width;
    double? height;
    if (altText.isNotEmpty) {
      final size = RegExp(r'^([0-9]+)?x?([0-9]+)?').firstMatch(altText.trim());
      width = double.tryParse(size?[1]?.toString().trim() ?? 'a');
      height = double.tryParse(size?[2]?.toString().trim() ?? 'a');
    }

    final image = config.imageBuilder?.call(context, imageUrl, width, height) ??
        SizedBox(
          width: width,
          height: height,
          child: Image(image: NetworkImage(imageUrl)),
        );

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            final uri = Uri.tryParse(linkUrl);
            if (uri != null) {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          child: image,
        ),
      ),
    );
  }
}

class MarkMd extends InlineMd {
  final Color textColor;

  MarkMd({required this.textColor});

  @override
  RegExp get exp => RegExp(r'==mark==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final content = match?[1] ?? '';
    final markStyle = (config.style ?? const TextStyle()).copyWith(
      color: textColor,
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, config.copyWith(style: markStyle), false),
      style: markStyle,
    );
  }
}

class ActiveMarkMd extends InlineMd {
  final GlobalKey? activeKey;

  ActiveMarkMd({this.activeKey});

  @override
  RegExp get exp => RegExp(r'==active==(.+?)==', dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final content = match?[1] ?? '';
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: KeyedSubtree(
        key: activeKey,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF44336).withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Text.rich(
            TextSpan(
              children: MarkdownComponent.generate(context, content, config, false),
              style: (config.style ?? const TextStyle()).copyWith(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class DetailsSummaryMd extends BlockMd {
  @override
  String get expString => r'<details[^>]*>\s*<summary[^>]*>(.*?)</summary>(.*?)</details>';

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final fullMatch = RegExp(r'<details[^>]*>\s*<summary[^>]*>(.*?)</summary>(.*?)</details>', dotAll: true).firstMatch(text);
    final summary = fullMatch?[1]?.trim() ?? 'Details';
    final body = fullMatch?[2]?.trim() ?? '';
    return _DetailsBlock(summary: summary, body: body, config: config);
  }
}

class _DetailsBlock extends StatefulWidget {
  final String summary;
  final String body;
  final GptMarkdownConfig config;

  const _DetailsBlock({required this.summary, required this.body, required this.config});

  @override
  State<_DetailsBlock> createState() => _DetailsBlockState();
}

class _DetailsBlockState extends State<_DetailsBlock> {
  bool _isOpen = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isOpen = !_isOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(_isOpen ? Icons.expand_less : Icons.expand_more, size: 18),
                  const SizedBox(width: 4),
                  Flexible(child: GptMarkdown(widget.summary)),
                ],
              ),
            ),
          ),
          if (_isOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: GptMarkdown(widget.body),
            ),
        ],
      ),
    );
  }
}
