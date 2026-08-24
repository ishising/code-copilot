/**
 * The repo, rendered by this app rather than watched through a video stream.
 *
 * That is the whole reason pointing works here. When the app owns the DOM it
 * knows exactly where every file row and every line of code sits, so a
 * highlight is an element lookup — exact, instant, free — instead of a vision
 * model guessing at coordinates in a compressed frame.
 */

import type { RepoSnapshot, TreeEntry } from './github';

/** Somebody else's code or build output: present in the tree, never worth
 *  showing to someone trying to understand what the team built. */
const NOISE = /^(node_modules|dist|build|out|vendor|\.git|\.next|target|coverage|__pycache__)(\/|$)/;

/** Rendering every line of a very large file costs more than it is worth; the
 *  agent reads the real text through `read_file` regardless of what is drawn. */
const MAX_RENDERED_LINES = 4000;

/** Where the user's attention is. This is how "what's this?" survives the
 *  move off video: a click or a selection in a panel we own is a far more
 *  precise pointing gesture than a finger in front of a camera. */
export type Focus = {
  path: string | null;
  visibleFrom: number;
  visibleTo: number;
  clickedLine: number | null;
  selectedText: string | null;
};

export type Viewer = {
  showFile: (path: string) => Promise<{ lines: number }>;
  focus: () => Focus;
  highlightLines: (
    path: string,
    from: number,
    to: number,
    label?: string,
  ) => Promise<void>;
  highlightTreeItem: (path: string, label?: string) => boolean;
  /** A quieter mark for the range the agent is *reading*, shown the moment it
   *  reads rather than when it finally gets around to pointing. */
  previewRange: (path: string, from: number, to: number) => Promise<void>;
  clearMarks: () => void;
  currentPath: () => string | null;
};

type Node = { name: string; path: string; children: Map<string, Node>; file: boolean };

function buildTree(entries: TreeEntry[]): Node {
  const root: Node = { name: '', path: '', children: new Map(), file: false };
  for (const entry of entries) {
    if (NOISE.test(entry.path)) continue;
    const parts = entry.path.split('/');
    let node = root;
    parts.forEach((part, index) => {
      const last = index === parts.length - 1;
      let child = node.children.get(part);
      if (child === undefined) {
        child = {
          name: part,
          path: parts.slice(0, index + 1).join('/'),
          children: new Map(),
          file: last && entry.type === 'blob',
        };
        node.children.set(part, child);
      }
      node = child;
    });
  }
  return root;
}

/** Folders before files, alphabetical within each — the ordering every file
 *  browser uses, so it reads as familiar rather than arbitrary. */
function sorted(node: Node): Node[] {
  return [...node.children.values()].sort((a, b) => {
    if (a.file !== b.file) return a.file ? 1 : -1;
    return a.name.localeCompare(b.name);
  });
}

/** Bring an element into view inside its scrolling ancestor.
 *
 *  `scrollIntoView` is the obvious call and the wrong one here: it silently
 *  does nothing when the panel measures zero height — which happens while the
 *  window is being resized, restored, or laid out — and the failure mode is
 *  the agent highlighting line 200 while the user stares at line 1. Computing
 *  the offset directly always moves, and degrades to "put it at the top"
 *  rather than to "do nothing". */
function bringIntoView(host: HTMLElement, anchor: HTMLElement): void {
  const centred = anchor.offsetTop - host.clientHeight / 2 + anchor.offsetHeight / 2;
  const top = Math.max(0, Math.min(centred, host.scrollHeight - host.clientHeight));
  // Assigning scrollTop rather than scrollTo({behavior:'smooth'}): smooth
  // scrolling is asynchronous and is a silent no-op in some environments
  // (a backgrounded tab, reduced-motion settings, headless rendering), and a
  // highlight the view never travels to is indistinguishable to the user from
  // no highlight at all. A jump always lands, and the caption above the block
  // tells them where they arrived.
  host.scrollTop = top;
}

export function createViewer(options: {
  treeHost: HTMLElement;
  codeHost: HTMLElement;
  crumb: HTMLElement;
  snapshot: RepoSnapshot;
  load: (path: string) => Promise<{ text: string; lines: number }>;
  onOpen?: (path: string) => void;
}): Viewer {
  const { treeHost, codeHost, crumb, snapshot, load } = options;

  const fileRows = new Map<string, HTMLElement>();
  /** Every row, folders included — the agent points at `src/auth/` as often
   *  as it points at a file, and folders are not in `fileRows`. */
  const allRows = new Map<string, HTMLElement>();
  let current: string | null = null;
  let marked: HTMLElement[] = [];
  let clickedLine: number | null = null;

  // A click in the code panel is the user pointing. Recording which line they
  // hit is what lets them ask "what's this?" without naming anything.
  codeHost.addEventListener('click', (event) => {
    const row = (event.target as HTMLElement | null)?.closest<HTMLElement>('.code-line');
    const line = row?.dataset['line'];
    if (line === undefined) return;
    clickedLine = Number(line);
    for (const el of codeHost.querySelectorAll('.picked')) el.classList.remove('picked');
    row?.classList.add('picked');
  });

  // ---- file tree ----

  function renderNode(node: Node, depth: number, into: HTMLElement): void {
    for (const child of sorted(node)) {
      const row = document.createElement('div');
      row.className = child.file ? 'row file' : 'row dir';
      row.style.paddingLeft = `${depth * 12 + 10}px`;
      row.textContent = child.file ? child.name : `${child.name}/`;
      into.appendChild(row);
      allRows.set(child.path, row);

      if (child.file) {
        fileRows.set(child.path, row);
        row.onclick = () => void showFile(child.path);
        continue;
      }

      const kids = document.createElement('div');
      // Root-level folders start open; anything deeper starts closed, so the
      // first impression of a repo is its shape and not a wall of paths.
      kids.hidden = depth > 0;
      row.classList.toggle('closed', kids.hidden);
      into.appendChild(kids);
      renderNode(child, depth + 1, kids);
      row.onclick = () => {
        kids.hidden = !kids.hidden;
        row.classList.toggle('closed', kids.hidden);
      };
    }
  }

  renderNode(buildTree(snapshot.entries), 0, treeHost);

  /** Reveal a row by opening every collapsed folder above it. Accepts a
   *  trailing slash, because the agent says `src/auth/` as often as not. */
  function revealRow(path: string): HTMLElement | null {
    const row = allRows.get(path) ?? allRows.get(path.replace(/\/+$/, ''));
    if (row === undefined) return null;
    for (
      let parent = row.parentElement;
      parent !== null && parent !== treeHost;
      parent = parent.parentElement
    ) {
      if (parent.hidden) {
        parent.hidden = false;
        parent.previousElementSibling?.classList.remove('closed');
      }
    }
    return row;
  }

  // ---- code panel ----

  function clearMarks(): void {
    for (const el of marked) {
      el.classList.remove('marked', 'marked-row', 'previewed');
      el.querySelector('.line-label')?.remove();
    }
    for (const el of codeHost.querySelectorAll('.label-row')) el.remove();
    marked = [];
  }

  /** The caption sits in its own row above the block rather than floating
   *  over it — an overlay covers the very code it is drawing attention to. */
  function captionAbove(anchor: HTMLElement, label: string): void {
    const row = document.createElement('div');
    row.className = 'label-row';
    const tag = document.createElement('span');
    tag.className = 'line-label';
    tag.textContent = label;
    row.appendChild(tag);
    anchor.parentElement?.insertBefore(row, anchor);
  }

  async function showFile(path: string): Promise<{ lines: number }> {
    if (current === path) {
      return { lines: codeHost.childElementCount };
    }
    clearMarks();
    codeHost.textContent = '';
    crumb.textContent = path;
    current = path;

    for (const [rowPath, row] of fileRows) {
      row.classList.toggle('open', rowPath === path);
    }
    revealRow(path)?.scrollIntoView({ block: 'nearest' });

    const { text, lines } = await load(path);
    const rendered = text.split('\n').slice(0, MAX_RENDERED_LINES);
    const fragment = document.createDocumentFragment();

    rendered.forEach((line, index) => {
      const row = document.createElement('div');
      row.className = 'code-line';
      row.dataset['line'] = String(index + 1);
      const number = document.createElement('span');
      number.className = 'line-no';
      number.textContent = String(index + 1);
      const body = document.createElement('span');
      body.className = 'line-text';
      // A blank line still needs height, or highlight ranges spanning it
      // collapse and the marked block looks like it skipped a line.
      body.textContent = line === '' ? ' ' : line;
      row.append(number, body);
      fragment.appendChild(row);
    });

    if (lines > MAX_RENDERED_LINES) {
      const note = document.createElement('div');
      note.className = 'code-note';
      note.textContent = `… ${lines - MAX_RENDERED_LINES} more lines not shown`;
      fragment.appendChild(note);
    }

    codeHost.appendChild(fragment);
    codeHost.scrollTop = 0;
    options.onOpen?.(path);
    return { lines };
  }

  /** Which lines are actually on screen, from the first row's height. Read
   *  live rather than cached because the panel resizes with the window. */
  function visibleRange(): { from: number; to: number } {
    const first = codeHost.querySelector<HTMLElement>('.code-line');
    const height = first?.offsetHeight ?? 0;
    // A minimized or hidden window reports a zero-height panel. Reporting
    // "lines 1 to 0" from that would have the agent confidently discussing a
    // range that does not exist, so an unmeasurable panel says so instead.
    if (height === 0 || codeHost.clientHeight === 0) return { from: 0, to: 0 };
    const from = Math.floor(codeHost.scrollTop / height) + 1;
    return { from, to: from + Math.ceil(codeHost.clientHeight / height) - 1 };
  }

  return {
    showFile,
    currentPath: () => current,
    clearMarks,

    focus() {
      const { from, to } = visibleRange();
      const selection = window.getSelection()?.toString().trim() ?? '';
      return {
        path: current,
        visibleFrom: from,
        visibleTo: to,
        clickedLine,
        selectedText: selection === '' ? null : selection.slice(0, 2000),
      };
    },

    async highlightLines(path, from, to, label) {
      await showFile(path);
      clearMarks();
      const first = Math.max(1, Math.min(from, to));
      const last = Math.max(from, to);
      for (let line = first; line <= last; line += 1) {
        const row = codeHost.querySelector<HTMLElement>(`[data-line="${line}"]`);
        if (row === null) continue;
        row.classList.add('marked');
        marked.push(row);
      }
      const anchor = marked[0];
      if (anchor === undefined) return;
      if (label !== undefined && label !== '') captionAbove(anchor, label);
      bringIntoView(codeHost, anchor);
    },

    async previewRange(path, from, to) {
      await showFile(path);
      clearMarks();
      const first = Math.max(1, Math.min(from, to));
      const last = Math.max(from, to);
      for (let line = first; line <= last; line += 1) {
        const row = codeHost.querySelector<HTMLElement>(`[data-line="${line}"]`);
        if (row === null) continue;
        row.classList.add('previewed');
        marked.push(row);
      }
      const anchor = marked[0];
      if (anchor !== undefined) bringIntoView(codeHost, anchor);
    },

    highlightTreeItem(path, label) {
      clearMarks();
      const row = revealRow(path);
      if (row === null) return false;
      row.classList.add('marked-row');
      marked.push(row);
      if (label !== undefined && label !== '') {
        const tag = document.createElement('span');
        tag.className = 'line-label';
        tag.textContent = label;
        row.appendChild(tag);
      }
      bringIntoView(treeHost, row);
      return true;
    },
  };
}
