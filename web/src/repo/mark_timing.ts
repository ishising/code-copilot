/**
 * When the mark goes up.
 *
 * A realtime model emits its function calls at the END of a turn, so an
 * explicit `highlight_lines` typically arrives as the audio stops — the user
 * hears "this block here" with nothing marked, then sees the mark once the
 * sentence is over. Nothing in the SDK can reorder that: it is the provider's
 * generation order, upstream of the transport. The SDK's own guidance (see
 * the `garden-doctor` example) is to accept the lag and write the persona to
 * expect it, which is right when the mark *confirms* what was said. Here the
 * mark is *direction* — the user cannot read the code, so a late mark means
 * they spend the whole explanation looking in the wrong place.
 *
 * So we use two signals that do arrive in the right order: the agent must read
 * a range before it can describe it, and the transcript stream tells us the
 * moment it starts speaking. Hold the range it read; promote it on the first
 * word of the next turn. The agent's own `highlight_lines` still lands later
 * and refines it — narrower lines, plus the caption.
 */

export type PendingMark = {
  path: string;
  from: number;
  to: number;
  /** When the read happened, epoch ms. */
  at: number;
};

/** Beyond this the read is stale: the agent read something, then went and did
 *  other things, and whatever it is saying now is unlikely to be about it.
 *  Promoting then would point the user confidently at the wrong code. */
export const PENDING_MARK_TTL_MS = 20_000;

/** The mark to raise for this transcript event, or `null` to raise none.
 *
 *  Pure, so the timing rule can be tested without standing up a live voice
 *  session — which is exactly the part that is awkward to exercise by hand.
 */
export function markToPromote(
  event: { role: 'user' | 'assistant' },
  pending: PendingMark | null,
  now: number,
): PendingMark | null {
  // The user talking is not the agent about to explain something.
  if (event.role !== 'assistant') return null;
  if (pending === null) return null;
  if (now - pending.at > PENDING_MARK_TTL_MS) return null;
  return pending;
}
