// What in a message is markup, and what is a reader writing about markup.
//
// This is the only guess the renderer still makes, and it is a small one: the
// browser parses everything, so the question is not "is this tag block or
// inline" (the parser knows) or "is this tag closed" (the parser closes it) —
// only "did the author mean an element here at all". A model writing
// `он прошептал <вздох>` means the word, not an element.
//
// The rule, in order:
//   1. a name the HTML/SVG/MathML vocabulary defines is markup, always;
//   2. any other name is markup if the message's own CSS styles it (that is
//      how `<loomledger>` and friends declare themselves), or if it appears as
//      a matched open/close pair;
//   3. anything else is text, and its angle brackets are escaped.
//
// What this replaces: the "orphan" counter (a tag was text if its name
// occurred exactly once in the message) and the hand-kept `blockTags` list.

/** One tag, with quoted attribute values that may contain `>`. */
export const TAG_REGEX = /<(?:[^"'>]|"[^"]*"|'[^']*')*>/g;

/** The tag's name, lower-cased, or '' for a comment / doctype / stray `<`. */
export function tagName(tag) {
  const match = /^<\/?([A-Za-z][A-Za-z0-9-]*)/.exec(tag);
  return match ? match[1].toLowerCase() : '';
}

export function isClosingTag(tag) {
  return /^<\//.test(tag);
}

// Every element name the HTML, SVG and MathML vocabularies define, including
// the deprecated ones a model still writes (`<font>`, `<center>`, `<marquee>`).
// A name in this set is markup whatever the message does with it.
const HTML_ELEMENTS = new Set(`
a abbr acronym address applet area article aside audio b base basefont bdi bdo
big blink blockquote body br button canvas caption center cite code col colgroup
data datalist dd del details dfn dialog dir div dl dt em embed fieldset
figcaption figure font footer form frame frameset h1 h2 h3 h4 h5 h6 head header
hgroup hr html i iframe img input ins kbd label legend li link main map mark
marquee menu meta meter nav nobr noscript object ol optgroup option output p
param picture plaintext pre progress q rb rp rt rtc ruby s samp script search
section select slot small source spacer span strike strong style sub summary
sup table tbody td template textarea tfoot th thead time title tr track tt u ul
var video wbr xmp
`.trim().split(/\s+/));

const SVG_ELEMENTS = new Set(`
svg altglyph animate animatemotion animatetransform circle clippath defs desc
ellipse feblend fecolormatrix fecomponenttransfer fecomposite feconvolvematrix
fediffuselighting fedisplacementmap fedropshadow feflood fefunca fefuncb
fefuncg fefuncr fegaussianblur feimage femerge femergenode femorphology
feoffset fepointlight fespecularlighting fespotlight fetile feturbulence
filter foreignobject g image line lineargradient marker mask metadata mpath
path pattern polygon polyline radialgradient rect set stop switch symbol text
textpath tspan use view
`.trim().split(/\s+/));

const MATHML_ELEMENTS = new Set(`
math maction menclose merror mfenced mfrac mglyph mi mlabeledtr mmultiscripts
mn mo mover mpadded mphantom mroot mrow ms mspace msqrt mstyle msub msubsup
msup mtable mtd mtext mtr munder munderover semantics annotation
`.trim().split(/\s+/));

export function isKnownElement(name) {
  return HTML_ELEMENTS.has(name) || SVG_ELEMENTS.has(name) ||
    MATHML_ELEMENTS.has(name);
}

/** Elements whose content is raw text: markdown never reaches inside them. */
export const RAW_TEXT_ELEMENTS = new Set([
  'script', 'style', 'pre', 'code', 'textarea', 'title', 'xmp', 'plaintext',
]);

/** Element names a `<style>` block in the message uses as a type selector. */
export function styledElementNames(text) {
  const names = new Set();
  const styles = text.match(/<style\b[^>]*>[\s\S]*?(?:<\/style>|$)/gi) || [];
  for (const block of styles) {
    const selectors = block
      // Declarations carry property names that would otherwise read as
      // element names (`background`, `filter`, `mask`).
      .replace(/\{[^}]*\}?/g, ' ')
      // At-rule preludes name fonts, urls and media features, not elements.
      .replace(/@[^;{]*/g, ' ')
      // A class, id, attribute or pseudo is not a type selector.
      .replace(/\[[^\]]*\]/g, ' ')
      .replace(/[.#:][A-Za-z0-9_-]+(?:\([^)]*\))?/g, ' ');
    const TYPE_SELECTOR = /(?:^|[\s,>+~])([A-Za-z][A-Za-z0-9-]*)/g;
    let match;
    while ((match = TYPE_SELECTOR.exec(selectors)) !== null) {
      names.add(match[1].toLowerCase());
    }
  }
  return names;
}

/**
 * Escapes the tags in [text] that are prose rather than markup, and leaves
 * every other character untouched. The result is what gets parsed.
 *
 * [styledNames] is the set of element names the message's CSS styles. The
 * caller passes it in when `<style>` and `<script>` bodies are masked out of
 * [text] — which they must be, because `i<n; i++) { if (i>` inside a script is
 * a tag to this scan, and escaping it corrupts the script.
 */
export function escapeProseTags(text, styledNames) {
  const styled = styledNames || styledElementNames(text);
  const opened = new Set();
  const closed = new Set();
  TAG_REGEX.lastIndex = 0;
  let match;
  while ((match = TAG_REGEX.exec(text)) !== null) {
    const name = tagName(match[0]);
    if (!name) continue;
    (isClosingTag(match[0]) ? closed : opened).add(name);
  }

  return text.replace(TAG_REGEX, (tag) => {
    const name = tagName(tag);
    if (!name) return tag;
    if (isKnownElement(name)) return tag;
    if (styled.has(name)) return tag;
    if (opened.has(name) && closed.has(name)) return tag;
    return tag.replace(/</g, '&lt;').replace(/>/g, '&gt;');
  });
}
