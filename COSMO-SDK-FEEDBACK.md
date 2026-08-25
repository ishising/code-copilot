# Cosmo SDK feedback — screen recording & tool schemas

From building [code-copilot](https://github.com/ishising/code-copilot): a voice
agent that walks someone through a repository, web (`cosmo-ai@0.6.0`) and macOS
(`cosmo-swift-sdk@0.7.0`).

Getting screen recording working took four debugging cycles. Each failure
surfaced far from its cause, and none of them were visible in the SDK's own
error text. All four are fixable in the SDK.

## 1. `startScreenShare()` needs a user gesture and doesn't say so

**Highest value fix.** `getDisplayMedia()` requires transient user activation.
Calling `startScreenShare()` after `await agent.start()` — seconds and several
awaits past the click — always fails, with a bare `NotAllowedError: Permission
denied`. That is **byte-identical to the user cancelling the picker**, so there
is no way to tell "you called this from the wrong place" from "they said no".

Five sessions recorded nothing before we found it.

**Fix:** check `navigator.userActivation.isActive` before calling
`getDisplayMedia` and throw a distinct error:

```
screen_requires_user_gesture: call startScreenShare() from a click handler,
or acquire the stream in one and pass it to addVideoStream({ kind: 'screen' }).
```

## 2. `storeVideo: true` is silently meaningless without a video track

The name reads as "record video". It is retention-only ("narrowing only" in the
docs), so setting it on a session that publishes no video does nothing at all,
with no signal.

**Fix:** one-time console warning when `storeVideo: true` and no video track is
published for the session.

## 3. `ToolSchemaError` names the forbidden key, not the allowed set

`minItems` / `maxItems` on an array throws `forbidden_key`. The message doesn't
say what *is* allowed, so fixing it means reading `SCHEMA_ALLOWED_KEYS` out of
the dist bundle.

Worse, this throws at **session start**, so the symptom is "the session won't
connect" — which sends you to the transport, not to a tool definition.

Cross-SDK asymmetry worth documenting: the Swift builder has no `minItems`
parameter, so the same mistake **cannot compile** there while TypeScript accepts
it and fails at runtime.

**Fix:** include the permitted key set in the error message.

## 4. `agent.start()` resolving ≠ ready to carry a track

`addVideoStream` fails with `requires the session to be live, currently
connecting` when called right after `start()`.

Swift has no equivalent race — we measured `startScreenShare()` being accepted
immediately after `agent.start()` there.

**Fix:** await readiness internally, or document that `start()` resolving is not
the same moment as ready.

## 5. No server-side confirmation that video was retained

We could only confirm recording worked *indirectly*, via
`input_image_tokens` on `/sessions/{id}/usage`. The external API exposes no
media endpoints at all — `/recording`, `/recordings`, `/audio`, `/video`,
`/media`, `/artifacts`, `/assets`, `/download`, `/egress`, `/files` all 404, and
the session object carries no media URLs.

**Fix:** expose retained-artifact state on the session object. Separately: a
documented way to retrieve or export a session's audio+video would be valuable —
today it appears to be dashboard-only.

## What the SDK already gets right

`CredentialsFile` refuses a `COSMO_BASE_URL` that contradicts a stored key's
origin, rather than letting it earn an unexplained 401. That is exactly the
pattern items 1–4 are missing: **catch the contradiction where it happens, not
three layers downstream.**

A related trap outside the SDK, for the docs: `app.askcosmo.ai` and
`platform.askcosmo.ai` are separate installations with separate keys, and a
mismatch returns `401 No access to workspace '<id>' from this host` — which
reads as a bad key rather than a wrong address.
