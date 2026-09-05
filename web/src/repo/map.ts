/**
 * The map: what has been walked, and how the pieces connect.
 *
 * Two jobs, one structure.
 *
 * During a session it is the picture that a spoken walk cannot leave behind.
 * Six stops of accurate speech add up to nothing unless something records that
 * stop four was the room stop three sent you to — so the agent files every
 * stop here, *with* its connection to an earlier one, and the panel draws it.
 * That requirement is also the structural enforcement of "nothing stands
 * alone": a node cannot be filed without saying what it connects to.
 *
 * Afterwards it is the thing to review. It persists per repository, so the
 * next session opens with what was already covered instead of starting again,
 * and it exports as Markdown with a Mermaid diagram that GitHub renders.
 */

export type NodeKind = 'file' | 'concept' | 'layer' | 'step';

export type MapNode = {
  id: string;
  label: string;
  kind: NodeKind;
  path?: string;
  from?: number;
  to?: number;
  /** One line, in the world's terms, on what this is for. */
  note?: string;
  /** Insertion order — the order the walk visited things. */
  order: number;
};

export type MapEdge = { from: string; to: string; label?: string };

export type RepoMap = {
  repo: string;
  nodes: MapNode[];
  edges: MapEdge[];
  updated: number;
};

export type AddResult = {
  node: MapNode;
  created: boolean;
  connectedTo: MapNode | null;
  /** Set when `connectsTo` named something that is not on the map. */
  unknownConnection?: string;
};

const STORAGE_PREFIX = 'codecopilot.map.';
const BRIEF_BUDGET = 1400;

export function mapKey(ref: { owner: string; repo: string; subpath?: string }): string {
  return `${ref.owner}/${ref.repo}${ref.subpath === undefined ? '' : `/${ref.subpath}`}`;
}

/** A stable identifier from a label: lowercase words joined by underscores.
 *  Prefixed so it can never collide with Mermaid's own keywords (`end`,
 *  `graph`, `click`) — a node called "end" would otherwise break the diagram. */
export function slug(label: string): string {
  const base = label
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 40);
  return `n_${base === '' ? 'node' : base}`;
}

export class MapStore {
  private map: RepoMap;
  private listeners: (() => void)[] = [];

  constructor(public readonly key: string) {
    this.map = MapStore.load(key);
  }

  // ---- persistence ----

  private static load(key: string): RepoMap {
    const empty: RepoMap = { repo: key, nodes: [], edges: [], updated: 0 };
    try {
      const raw = localStorage.getItem(STORAGE_PREFIX + key);
      if (raw === null) return empty;
      const parsed = JSON.parse(raw) as Partial<RepoMap>;
      return {
        repo: key,
        nodes: Array.isArray(parsed.nodes) ? parsed.nodes : [],
        edges: Array.isArray(parsed.edges) ? parsed.edges : [],
        updated: typeof parsed.updated === 'number' ? parsed.updated : 0,
      };
    } catch {
      // A private window, cleared storage, or a browser that throws on the
      // accessor. The map still works for this session; it just won't persist.
      return empty;
    }
  }

  private save(): void {
    this.map.updated = Date.now();
    try {
      localStorage.setItem(STORAGE_PREFIX + this.key, JSON.stringify(this.map));
    } catch {
      // Same reasoning as load: persistence is a convenience, not a requirement.
    }
    for (const listener of this.listeners) listener();
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  // ---- reading ----

  get nodes(): readonly MapNode[] {
    return this.map.nodes;
  }

  get edges(): readonly MapEdge[] {
    return this.map.edges;
  }

  get isEmpty(): boolean {
    return this.map.nodes.length === 0;
  }

  /** When the map was last touched, or null if it has never been. */
  get updatedAt(): Date | null {
    return this.map.updated === 0 ? null : new Date(this.map.updated);
  }

  /** Lenient lookup: id, then exact label, then the best partial match. The
   *  agent refers back to things by what it called them out loud, which is
   *  rarely character-perfect. */
  find(nameOrId: string): MapNode | null {
    const needle = nameOrId.trim().toLowerCase();
    if (needle === '') return null;
    const byId = this.map.nodes.find((node) => node.id === nameOrId || node.id === slug(nameOrId));
    if (byId !== undefined) return byId;
    const exact = this.map.nodes.find((node) => node.label.toLowerCase() === needle);
    if (exact !== undefined) return exact;
    const partial = this.map.nodes
      .filter((node) => {
        const label = node.label.toLowerCase();
        return label.includes(needle) || needle.includes(label);
      })
      .sort((a, b) => b.label.length - a.label.length);
    return partial[0] ?? null;
  }

  // ---- writing ----

  add(input: {
    label: string;
    kind?: NodeKind;
    path?: string;
    from?: number;
    to?: number;
    note?: string;
    connectsTo?: string;
    relationship?: string;
  }): AddResult {
    const label = input.label.trim();
    const existing = this.map.nodes.find((node) => node.label.toLowerCase() === label.toLowerCase());

    let node: MapNode;
    let created = false;
    if (existing !== undefined) {
      // Filing the same thing twice is a correction, not a duplicate: keep the
      // node, take any new detail, and let a fresh connection be added.
      node = existing;
      if (input.kind !== undefined) node.kind = input.kind;
      if (input.path !== undefined) node.path = input.path;
      if (input.from !== undefined) node.from = input.from;
      if (input.to !== undefined) node.to = input.to;
      if (input.note !== undefined && input.note.trim() !== '') node.note = input.note.trim();
    } else {
      let id = slug(label);
      while (this.map.nodes.some((other) => other.id === id)) id = `${id}_${this.map.nodes.length}`;
      node = {
        id,
        label,
        kind: input.kind ?? 'concept',
        order: this.map.nodes.length,
      };
      if (input.path !== undefined) node.path = input.path;
      if (input.from !== undefined) node.from = input.from;
      if (input.to !== undefined) node.to = input.to;
      if (input.note !== undefined && input.note.trim() !== '') node.note = input.note.trim();
      this.map.nodes.push(node);
      created = true;
    }

    let connectedTo: MapNode | null = null;
    let unknownConnection: string | undefined;
    if (input.connectsTo !== undefined && input.connectsTo.trim() !== '') {
      const target = this.find(input.connectsTo);
      if (target !== null && target.id !== node.id) {
        connectedTo = target;
        const relationship = input.relationship?.trim();
        const duplicate = this.map.edges.some(
          (edge) => edge.from === target.id && edge.to === node.id,
        );
        if (!duplicate) {
          const edge: MapEdge = { from: target.id, to: node.id };
          if (relationship !== undefined && relationship !== '') edge.label = relationship;
          this.map.edges.push(edge);
        }
      } else if (target === null) {
        unknownConnection = input.connectsTo;
      }
    }

    this.save();
    const result: AddResult = { node, created, connectedTo };
    if (unknownConnection !== undefined) result.unknownConnection = unknownConnection;
    return result;
  }

  clear(): void {
    this.map = { repo: this.key, nodes: [], edges: [], updated: 0 };
    try {
      localStorage.removeItem(STORAGE_PREFIX + this.key);
    } catch {
      // Nothing to do; see load().
    }
    for (const listener of this.listeners) listener();
  }

  // ---- rendering ----

  /** Mermaid source. Labels are quoted, and quotes inside them escaped the way
   *  Mermaid wants, so a label like `the "front desk"` cannot break the whole
   *  diagram. */
  toMermaid(): string {
    const lines = ['flowchart TD'];
    const styleFor: Record<NodeKind, string> = {
      file: 'fill:#161a23,stroke:#6ea8fe,color:#e6e9ef',
      layer: 'fill:#1d1a12,stroke:#ffd479,color:#e6e9ef',
      concept: 'fill:#141821,stroke:#5c6675,color:#e6e9ef',
      step: 'fill:#141821,stroke:#5ad19b,color:#e6e9ef',
    };
    for (const node of this.map.nodes) {
      const title = node.path === undefined ? node.label : `${node.label}\n${where(node)}`;
      lines.push(`  ${node.id}["${escape(title)}"]`);
      lines.push(`  style ${node.id} ${styleFor[node.kind]}`);
    }
    for (const edge of this.map.edges) {
      lines.push(
        edge.label === undefined
          ? `  ${edge.from} --> ${edge.to}`
          : `  ${edge.from} -->|"${escape(edge.label)}"| ${edge.to}`,
      );
    }
    return lines.join('\n');
  }

  /** The review document: the diagram GitHub will render, then every stop
   *  with its one-line meaning and exactly where it lives. */
  toMarkdown(): string {
    const when = this.updatedAt?.toLocaleString() ?? 'never';
    const rows = [...this.map.nodes]
      .sort((a, b) => a.order - b.order)
      .map((node, index) => {
        const meaning = node.note ?? '';
        const place = node.path === undefined ? '' : `\`${where(node)}\``;
        return `| ${index + 1} | **${node.label}** | ${meaning} | ${place} |`;
      });
    return [
      `# Map of ${this.map.repo}`,
      '',
      `_Updated ${when}. ${this.map.nodes.length} stops, ${this.map.edges.length} connections._`,
      '',
      '```mermaid',
      this.toMermaid(),
      '```',
      '',
      '| # | Stop | What it is for | Where |',
      '| --- | --- | --- | --- |',
      ...rows,
      '',
    ].join('\n');
  }

  /** What the agent is told at the start of a later session. Compact: a
   *  realtime model's working memory is small, and this is orientation, not
   *  the record. */
  briefSection(): string {
    if (this.isEmpty) return '';
    const ordered = [...this.map.nodes].sort((a, b) => a.order - b.order);
    const stops = ordered.map((node) => {
      const inbound = this.map.edges.find((edge) => edge.to === node.id);
      const fromLabel =
        inbound === undefined
          ? null
          : (this.map.nodes.find((other) => other.id === inbound.from)?.label ?? null);
      const link =
        fromLabel === null
          ? ''
          : ` (${inbound?.label === undefined ? 'from' : inbound.label + ' ←'} ${fromLabel})`;
      const meaning = node.note === undefined ? '' : ` — ${node.note}`;
      return `- ${node.label}${link}${meaning}`;
    });
    let body = stops.join('\n');
    if (body.length > BRIEF_BUDGET) body = `${body.slice(0, BRIEF_BUDGET)}\n- …`;
    return [
      'MAP FROM EARLIER SESSIONS — what this person has already walked, in',
      'order, with how each stop connected to the one before. Continue from',
      'here rather than starting again, unless they ask for something new:',
      body,
    ].join('\n');
  }
}

function where(node: MapNode): string {
  if (node.path === undefined) return '';
  if (node.from === undefined) return node.path;
  return node.to === undefined || node.to === node.from
    ? `${node.path}:${node.from}`
    : `${node.path}:${node.from}-${node.to}`;
}

function escape(text: string): string {
  return text.replace(/"/g, '#quot;').replace(/\n/g, '<br/>');
}
