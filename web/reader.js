// Turns Markdown into the page. The app calls render(markdown, base) on open and on every
// change to the file; the page is never reloaded, so the scroll position survives edits.
'use strict';

const content = document.getElementById('content');

const escapeHTML = s => s.replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function tex(source, displayMode) {
  try {
    return katex.renderToString(source, { displayMode, throwOnError: false, output: 'html' });
  } catch {
    return `<code class="math-error">${escapeHTML(source)}</code>`;
  }
}

// $…$, \(…\) inline; $$…$$, \[…\] display. Maths is tokenised before Markdown sees it, so
// underscores and asterisks inside it are not read as emphasis. A $ followed by a space or
// closed before a digit ("$5 and $10") is left as a dollar sign.
const mathBlock = {
  name: 'mathBlock',
  level: 'block',
  start(src) { const i = src.search(/^(?:\$\$|\\\[)/m); return i < 0 ? undefined : i; },
  tokenizer(src) {
    const m = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])[ \t]*(?:\n|$)/.exec(src);
    if (m) return { type: 'mathBlock', raw: m[0], text: (m[1] ?? m[2]).trim() };
  },
  renderer(token) { return `<div class="math-block">${tex(token.text, true)}</div>\n`; },
};

const mathInline = {
  name: 'mathInline',
  level: 'inline',
  start(src) { const i = src.search(/\$|\\\(/); return i < 0 ? undefined : i; },
  tokenizer(src) {
    let m = /^\$\$([\s\S]+?)\$\$/.exec(src);
    if (m) return { type: 'mathInline', raw: m[0], text: m[1].trim(), display: true };
    m = /^\$(?!\s)((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)/.exec(src);
    if (m) return { type: 'mathInline', raw: m[0], text: m[1], display: false };
    m = /^\\\(([\s\S]+?)\\\)/.exec(src);
    if (m) return { type: 'mathInline', raw: m[0], text: m[1], display: false };
  },
  renderer(token) { return tex(token.text, token.display); },
};

// Obsidian-style [[Note]], [[Note#Heading]] and [[Note|label]]. The link points at Note.md
// next to this file; the app looks further afield (the whole vault) if it is not there.
const wikilink = {
  name: 'wikilink',
  level: 'inline',
  start(src) { const i = src.indexOf('[['); return i < 0 ? undefined : i; },
  tokenizer(src) {
    const m = /^\[\[([^\]|#\n]+)(#[^\]|\n]*)?(?:\|([^\]\n]+))?\]\]/.exec(src);
    if (m) return { type: 'wikilink', raw: m[0], target: m[1].trim(), heading: m[2] ?? '', label: m[3] };
  },
  renderer(token) {
    const file = /\.[A-Za-z0-9]{1,5}$/.test(token.target) ? token.target : `${token.target}.md`;
    const label = token.label ?? (token.target + token.heading.replace('#', ' › '));
    return `<a class="wikilink" href="${escapeHTML(encodeURI(file))}">${escapeHTML(label)}</a>`;
  },
};

marked.use({ gfm: true, extensions: [mathBlock, mathInline, wikilink] });
hljs.configure({ ignoreUnescapedHTML: true });

function slug(text, seen) {
  const base = text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, '-') || 'section';
  const n = seen.get(base) ?? 0;
  seen.set(base, n + 1);
  return n ? `${base}-${n}` : base;
}

window.render = (markdown, base) => {
  document.querySelector('base').href = base;

  let front = '';
  const fm = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(markdown);
  if (fm) {
    front = `<pre class="frontmatter">${escapeHTML(fm[1])}</pre>\n`;
    markdown = markdown.slice(fm[0].length);
  }
  content.innerHTML = front + marked.parse(markdown);

  const seen = new Map();
  for (const h of content.querySelectorAll('h1, h2, h3, h4, h5, h6')) h.id = slug(h.textContent, seen);

  for (const code of content.querySelectorAll('pre code[class*="language-"]')) {
    const language = /language-(\S+)/.exec(code.className)[1];
    if (hljs.getLanguage(language)) hljs.highlightElement(code);
  }
};

// <base> points at the document's folder, so "#heading" links would otherwise resolve to
// the folder. Scroll to them here; every other link goes to the app.
document.addEventListener('click', event => {
  const link = event.target.closest('a[href^="#"]');
  if (!link) return;
  event.preventDefault();
  const id = decodeURIComponent(link.getAttribute('href').slice(1));
  const target = document.getElementById(id) ?? document.getElementById(slug(id, new Map()));
  target?.scrollIntoView({ behavior: 'smooth', block: 'start' });
});
