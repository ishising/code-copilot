/**
 * What the agent can do to the repo view.
 *
 * These replace the vision pipeline the first version used. The SDK's
 * `cosmo_sdk_draw_box` renderer exists to draw where `cosmo_detect_objects`
 * found something — an object locator built for cameras, which is why it
 * could not reliably find a filename in a screenshot of a code listing. Here
 * the app renders the repo itself, so pointing is an element lookup against
 * the DOM: exact, instant, and impossible to hallucinate a position for.
 */

import type { ClientToolSpec } from 'cosmo-ai';
import { tool } from 'cosmo-ai/tool';

import type { RepoRef } from './github';
import { fetchFile } from './github';
import type { MapStore, NodeKind } from './map';
import type { Viewer } from './viewer';

/** A realtime model's working memory is small, so a file arrives in slices.
 *  Past this the model is told to ask for a line range instead. */
const TEXT_BUDGET = 8000;

/** Only mark a read range when it is small enough to mean "this bit". A model
 *  skimming 300 lines to orient itself is not pointing at anything. */
const PREVIEW_MAX_LINES = 60;

export type RepoTools = {
  specs: ClientToolSpec[];
  /** Files already pulled this session, so repeated reads are free. */
  cache: Map<string, string>;
};

export type RepoToolsOptions = {
  ref: RepoRef;
  viewer: Viewer;
  /** Exact, written record of what the agent touched. The spoken transcript
   *  is a transcription of synthesized speech and will mangle identifiers no
   *  matter how well the agent pronounces them, so the precise spelling has
   *  to reach the user through a channel that never passes through audio. */
  onActivity: (text: string) => void;
  /** Source files pulled at ingest. Search reads from here, and every
   *  `read_file` on a prefetched path is a cache hit. */
  cache: Map<string, string>;
  /** Every path in the repository, so search can match filenames even for
   *  files too large or too binary to have been prefetched. */
  allPaths: string[];
  /** Fired when the agent reads a tight range — the range it is, in a moment,
   *  about to talk about. The caller uses this to put the mark up when speech
   *  starts rather than when the model finally emits `highlight_lines`. */
  onRead?: (path: string, from: number, to: number) => void;
  /** Fired when the agent offers ways into the repository at the top of a
   *  session. The caller draws a button per route. The agent picks these
   *  rather than a heuristic over the file tree, because it has just read the
   *  summary and is the only thing here that knows which parts of *this*
   *  repository are worth an hour. */
  onRoutes?: (routes: Route[]) => void;
  /** The map the agent files each stop into. Optional only so tests can build
   *  the tools without one; the app always passes it. */
  map?: MapStore;
};

/** One thing the agent offers to walk, rendered as a button. */
export type Route = { label: string; summary: string };

export function repoTools(options: RepoToolsOptions): RepoTools {
  const { ref, viewer, onActivity, cache, allPaths, onRead, onRoutes, map } = options;

  async function textOf(path: string): Promise<string> {
    const hit = cache.get(path);
    if (hit !== undefined) return hit;
    const { text } = await fetchFile(ref, path);
    cache.set(path, text);
    return text;
  }

  const readFile = tool({
    name: 'read_file',
    description:
      'Read the real text of one file in the repository, and open it in the ' +
      "user's view so they see what you are looking at. Give a line range " +
      'for a long file. Use this before describing what any code does — you ' +
      'are reading the actual file, not guessing from its name.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: "Path from the repository root, e.g. 'src/auth/login.ts'.",
        },
        from_line: {
          type: 'integer',
          minimum: 1,
          description: 'First line to return. Omit to start at the top.',
        },
        to_line: {
          type: 'integer',
          minimum: 1,
          description: 'Last line to return. Omit for as much as fits.',
        },
      },
      required: ['path'],
    },
    handler: async (args) => {
      const path = String(args['path'] ?? '');
      try {
        const text = await textOf(path);
        const all = text.split('\n');
        const from = Math.max(1, Number(args['from_line'] ?? 1));
        const to = Math.min(all.length, Number(args['to_line'] ?? all.length));
        const slice = all.slice(from - 1, to);

        let body = slice.join('\n');
        let truncated = false;
        if (body.length > TEXT_BUDGET) {
          body = body.slice(0, TEXT_BUDGET);
          truncated = true;
        }

        // Opening it is the point: the user's screen follows the agent's
        // attention without anyone having to ask for it.
        //
        // Marking the range read is a timing fix. A realtime model tends to
        // emit its function calls at the END of a turn, so an explicit
        // `highlight_lines` often lands as the audio stops — the user hears
        // "this block here" with nothing marked, then sees the mark once the
        // sentence is over. Reading happens before speaking, so marking what
        // was read puts something correct on screen first, and the deliberate
        // highlight upgrades it when it arrives.
        await viewer.showFile(path);
        const asked = args['from_line'] !== undefined && args['to_line'] !== undefined;
        if (asked && to - from <= PREVIEW_MAX_LINES) {
          await viewer.previewRange(path, from, to);
          onRead?.(path, from, to);
        }
        onActivity(`opened ${path}`);

        return {
          path,
          total_lines: all.length,
          from_line: from,
          to_line: truncated ? from + body.split('\n').length - 1 : to,
          truncated,
          text: body,
        };
      } catch (error) {
        const reason = error instanceof Error ? error.message : 'could not read';
        onActivity(`could not open ${path} — ${reason}`);
        return { path, error: reason };
      }
    },
  });

  const highlightLines = tool({
    name: 'highlight_lines',
    description:
      "Highlight a range of lines in the user's view and scroll to it, so " +
      'they can see exactly what you are talking about while you talk. Use ' +
      'this whenever your answer is about specific code. Visual only.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Path from the repository root.' },
        from_line: { type: 'integer', minimum: 1, description: 'First line to mark.' },
        to_line: { type: 'integer', minimum: 1, description: 'Last line to mark.' },
        label: {
          type: 'string',
          maxLength: 60,
          description: "Short caption, e.g. 'this is where the password is checked'.",
        },
      },
      required: ['path', 'from_line', 'to_line'],
    },
    handler: async (args) => {
      const path = String(args['path'] ?? '');
      try {
        await viewer.highlightLines(
          path,
          Number(args['from_line']),
          Number(args['to_line']),
          args['label'] === undefined ? undefined : String(args['label']),
        );
        onActivity(`highlighted ${path} lines ${args['from_line']}-${args['to_line']}`);
        return { shown: true };
      } catch (error) {
        const reason = error instanceof Error ? error.message : `could not open ${path}`;
        onActivity(`could not highlight ${path} — ${reason}`);
        return { shown: false, reason };
      }
    },
  });

  const highlightPath = tool({
    name: 'highlight_path',
    description:
      "Highlight a file or folder in the user's file tree and scroll to it. " +
      'Use this when you are talking about where something lives rather than ' +
      'what the code says. Visual only.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: "Path from the repository root — a file or a folder.",
        },
        label: { type: 'string', maxLength: 60, description: 'Short caption.' },
      },
      required: ['path'],
    },
    handler: async (args) => {
      const path = String(args['path'] ?? '');
      const found = viewer.highlightTreeItem(
        path,
        args['label'] === undefined ? undefined : String(args['label']),
      );
      onActivity(found ? `pointed at ${path}` : `no such path: ${path}`);
      return found
        ? { shown: true }
        : { shown: false, reason: `there is no ${path} in this repository` };
    },
  });

  const findInRepo = tool({
    name: 'find_in_repo',
    description:
      'Search the repository for a word — a function name, a route, a piece ' +
      'of text, a filename. Returns matching files with line numbers. This ' +
      'is how you follow a flow: search for where something is defined, then ' +
      'search for where it is called. Use it instead of guessing a path.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          minLength: 2,
          description: "What to look for, e.g. 'checkPassword' or '/api/login'.",
        },
      },
      required: ['query'],
    },
    handler: async (args) => {
      const query = String(args['query'] ?? '').trim();
      if (query.length < 2) return { query, matches: [], note: 'query too short' };
      const needle = query.toLowerCase();

      const paths = [...allPaths]
        .filter((path) => path.toLowerCase().includes(needle))
        .slice(0, 10);

      const matches: { path: string; line: number; text: string }[] = [];
      for (const [path, text] of cache) {
        if (matches.length >= 25) break;
        const lines = text.split('\n');
        for (let i = 0; i < lines.length && matches.length < 25; i += 1) {
          const line = lines[i];
          if (line !== undefined && line.toLowerCase().includes(needle)) {
            matches.push({ path, line: i + 1, text: line.trim().slice(0, 160) });
          }
        }
      }

      onActivity(`searched for "${query}" — ${matches.length} hits`);
      return {
        query,
        matching_paths: paths,
        matches,
        searched_files: cache.size,
        note:
          matches.length === 0 && paths.length === 0
            ? 'nothing found — try a shorter or different word'
            : undefined,
      };
    },
  });

  const offerRoutes = tool({
    name: 'offer_routes',
    description:
      'Offer the user three to five different ways into this repository, ' +
      'shown as buttons they can click. Call this once, at the start, after ' +
      'you have said what the software is — then stop talking and wait for ' +
      'them to choose. Draw the routes from the summary and make them about ' +
      'genuinely different things, not three flavours of how it starts up. ' +
      'At least one should be about what the software does rather than how ' +
      'it connects or configures itself.',
    parameters: {
      type: 'object',
      properties: {
        routes: {
          type: 'array',
          // No minItems/maxItems: the SDK allows only a fixed set of schema
          // keys and rejects the whole tool at session start otherwise, which
          // surfaces as a session that will not connect rather than as a bad
          // tool. The count lives in the description, where the model reads it.
          description: 'Three to five routes, most interesting first.',
          items: {
            type: 'object',
            properties: {
              label: {
                type: 'string',
                description:
                  "Short button text, a few words, in their language not the " +
                  "code's. E.g. 'How a question becomes speech'.",
              },
              summary: {
                type: 'string',
                description: 'One line on what they would come away understanding.',
              },
            },
            required: ['label', 'summary'],
          },
        },
      },
      required: ['routes'],
    },
    handler: async (args) => {
      const raw = Array.isArray(args['routes']) ? args['routes'] : [];
      const routes: Route[] = raw
        .map((item) => ({
          label: String((item as Route)?.label ?? '').trim(),
          summary: String((item as Route)?.summary ?? '').trim(),
        }))
        .filter((route) => route.label.length > 0);

      if (routes.length === 0) {
        return { shown: false, reason: 'no usable routes — give each one a label' };
      }

      onRoutes?.(routes);
      onActivity(`offered ${routes.length} routes`);
      return {
        shown: true,
        note:
          'The buttons are on their screen. Say they can pick one or just ' +
          'tell you what they want, then stop and wait.',
      };
    },
  });

  const userFocus = tool({
    name: 'user_focus',
    description:
      'Find out what the user is currently looking at: which file is open, ' +
      'which lines are on screen, which line they last clicked, and any text ' +
      'they selected. Call this FIRST whenever they say "this", "that", ' +
      '"here" or otherwise point without naming what they mean.',
    parameters: { type: 'object', properties: {} },
    handler: async () => {
      const focus = viewer.focus();
      if (focus.path === null) {
        return { nothing_open: true, hint: 'no file is open yet — the user is looking at the file tree' };
      }
      const measurable = focus.visibleFrom > 0 && focus.visibleTo >= focus.visibleFrom;
      return {
        path: focus.path,
        visible_lines: measurable
          ? `${focus.visibleFrom}-${focus.visibleTo}`
          : 'unknown — the window is hidden or minimized',
        clicked_line: focus.clickedLine,
        selected_text: focus.selectedText,
      };
    },
  });

  const addToMap = tool({
    name: 'add_to_map',
    description:
      'File the stop you just explained into the map the user can see and ' +
      'review later. Call this at EVERY stop, after highlighting. Give it the ' +
      "name you used out loud, one line on what it is for in the world's " +
      'terms, where it lives, and — this is the important part — which ' +
      'earlier stop it connects to and how. Filing the same name again ' +
      'updates it and can add a new connection, so use it to link things too.',
    parameters: {
      type: 'object',
      properties: {
        label: {
          type: 'string',
          maxLength: 60,
          description:
            "The name you used out loud, in their language. 'The front desk', " +
            "'where the line opens' — not a class name.",
        },
        kind: {
          type: 'string',
          enum: ['file', 'concept', 'layer', 'step'],
          description:
            "'file' for a specific file or lines, 'layer' for a whole part of the " +
            "system, 'step' for a moment in a flow, 'concept' for anything else.",
        },
        note: {
          type: 'string',
          maxLength: 140,
          description: 'One line on what it does for the anchor. Plain words.',
        },
        path: { type: 'string', description: 'File path, if it lives in one.' },
        from_line: { type: 'integer', minimum: 1 },
        to_line: { type: 'integer', minimum: 1 },
        connects_to: {
          type: 'string',
          description:
            'The label of an EARLIER stop this one connects to. Required for ' +
            'every stop after the first — the map is the connections.',
        },
        relationship: {
          type: 'string',
          maxLength: 40,
          description:
            "A short verb phrase for the arrow: 'sends you to', 'is inside', " +
            "'happens after', 'hides'.",
        },
      },
      required: ['label', 'note'],
    },
    handler: async (args) => {
      if (map === undefined) return { added: false, reason: 'no map in this session' };
      const label = String(args['label'] ?? '').trim();
      if (label === '') return { added: false, reason: 'give the stop a label' };

      const kind = args['kind'];
      const input: Parameters<MapStore['add']>[0] = { label };
      if (kind === 'file' || kind === 'concept' || kind === 'layer' || kind === 'step') {
        input.kind = kind as NodeKind;
      }
      if (typeof args['note'] === 'string') input.note = args['note'];
      if (typeof args['path'] === 'string' && args['path'] !== '') input.path = args['path'];
      if (args['from_line'] !== undefined) input.from = Number(args['from_line']);
      if (args['to_line'] !== undefined) input.to = Number(args['to_line']);
      if (typeof args['connects_to'] === 'string') input.connectsTo = args['connects_to'];
      if (typeof args['relationship'] === 'string') input.relationship = args['relationship'];

      const result = map.add(input);
      const connection =
        result.connectedTo === null ? '' : ` ← ${result.connectedTo.label}`;
      onActivity(`${result.created ? 'mapped' : 'updated'} "${result.node.label}"${connection}`);

      const reply: Record<string, unknown> = {
        added: true,
        label: result.node.label,
        connected_to: result.connectedTo?.label ?? null,
        stops_on_map: map.nodes.length,
      };
      if (result.unknownConnection !== undefined) {
        reply['note'] =
          `Nothing on the map is called "${result.unknownConnection}". Existing stops: ` +
          map.nodes.map((node) => node.label).join(', ') +
          '. File it again with one of those as connects_to.';
      } else if (result.connectedTo === null && map.nodes.length > 1) {
        reply['note'] =
          'This stop is not connected to anything. Unless it truly stands ' +
          'apart, file it again with connects_to set to an earlier stop.';
      }
      return reply;
    },
  });

  const mapSoFar = tool({
    name: 'map_so_far',
    description:
      'Read back the map: every stop filed so far, in order, with its ' +
      'connections. Use it for the recap every few stops, and whenever you ' +
      'are unsure what has already been covered.',
    parameters: { type: 'object', properties: {} },
    handler: async () => {
      if (map === undefined || map.isEmpty) return { stops: [], note: 'nothing mapped yet' };
      const stops = [...map.nodes]
        .sort((a, b) => a.order - b.order)
        .map((node) => {
          const inbound = map.edges.filter((edge) => edge.to === node.id);
          const from = inbound.map((edge) => {
            const source = map.nodes.find((other) => other.id === edge.from);
            return edge.label === undefined
              ? (source?.label ?? edge.from)
              : `${source?.label ?? edge.from} (${edge.label})`;
          });
          return { label: node.label, note: node.note ?? null, connected_from: from };
        });
      return { stops, count: stops.length };
    },
  });

  return {
    specs: [
      readFile,
      findInRepo,
      highlightLines,
      highlightPath,
      userFocus,
      offerRoutes,
      addToMap,
      mapSoFar,
    ],
    cache,
  };
}
