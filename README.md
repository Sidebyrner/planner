# Planner

One place for tasks and calendar, built to be driven by you and by your AI agents.

- **Tasks carry time.** Each task has an estimate, a due time and a priority. A task gets done by reserving blocks for it on the calendar.
- **Auto-scheduling.** "Plan my tasks" proposes blocks in your free working hours (earliest due first, then priority). You review them on the calendar, drop any you dislike, and book the rest.
- **Plain-language capture.** Type `Draft proposal by Friday 2h !high` or `Call supplier Monday 2pm 30 min`.
- **Google Calendar sync.** Your real meetings appear here; blocks you book here appear in Google. Moves and deletions go both ways.
- **MCP server.** Claude (or any MCP client) can read your agenda, add tasks, find free time and schedule work through `/mcp`.

Single user. One Node process, one SQLite file.

## Run it locally

Needs Node 22.13 or newer.

```bash
npm install
```

```bash
npm run build
```

```bash
npm start
```

Open http://localhost:8787. With no `.env`, there is no login and no Google sync; everything else works.

For development with reload, run `npm run dev` (server on 8787) and `npm run dev:web` (UI on 5173) in two terminals.

```bash
npm test
```

## Using it

| Do this | How |
| --- | --- |
| Add a task or event | Type in the top bar (press `/` to focus it). A preview shows how the line was read before you press Enter. |
| Schedule everything open | **Plan my tasks**, then **Book these blocks** |
| Schedule one task by hand | Drag it from the list onto the calendar |
| Move an event or block | Drag it, or click it and edit the times |
| Add an event | Click an empty spot on the calendar |
| Finish a task | Tick it. Blocks still ahead of it are released. |

How a typed line is read:

- A clock time makes it an **event**: `Lunch with Sam tomorrow at noon`, `Standup Monday 9-9:30am`
- Otherwise it is a **task**. `by`, `due` or `before` set the deadline, even with a time: `Send invoice by Monday 5pm`
- `45 min`, `2h`, `1.5 hours` set the estimate (or the event length)
- `!high`, `!low`, `urgent`, `p1`, `p3` set priority
- Start with `task:` or `event:` to force either

Working hours, working days, the longest single block and how far ahead to plan are in Settings.

## Connect an agent (MCP)

The endpoint is `<your address>/mcp`, Streamable HTTP, authenticated with `Authorization: Bearer <MCP_TOKEN>`.

Claude Code:

```bash
claude mcp add --transport http planner https://YOUR-APP.fly.dev/mcp --header "Authorization: Bearer YOUR_MCP_TOKEN"
```

Tools: `get_agenda`, `get_now`, `list_tasks`, `create_task`, `update_task`, `delete_task`, `set_checklist`, `check_item`, `list_waiting`, `list_projects`, `create_project`, `update_project`, `get_project`, `plan_week`, `weekly_review`, `list_events`, `create_event`, `update_event`, `delete_event`, `ignore_event`, `find_free_slots`, `propose_schedule`, `apply_schedule`, `auto_schedule`, `capture`, `get_settings`, `update_settings`, `mark_block`.

Set `WEBHOOK_URL` (and optionally `WEBHOOK_SECRET`) to get a `block.started` POST as each task block begins, with the block's tasks, the next unchecked step, links and contact. The body is signed in `X-Planner-Signature: sha256=<HMAC>`.

Then ask things like "what's on my plate today?", "add a 2-hour task to draft the winter menu, due Tuesday, and find time for it", or "I'm out Thursday afternoon, move my blocks".

The claude.ai and mobile apps add custom connectors through OAuth rather than a fixed bearer token, so this endpoint works with Claude Code and other clients that can send a header. Adding OAuth is the next step if you want it in those apps.

## Sync with the iOS and macOS apps

The native apps (in progress, see `docs/apple-and-proxmox-plan.md`) sign in with `Authorization: Bearer <DEVICE_TOKEN>` and call the same `/api` endpoints as the web app, plus one more:

`PUT /api/device/events` with `{ from, to, events, blockChanges? }`

- `events`: every event on the device's calendars in the window, except the "Planner" calendar the app writes task blocks into. Each has `externalId` (one per occurrence for recurring events), `title`, `startAt`, `endAt`, and optional `notes` and `allDay`. This replaces the previous mirror for the window, so the scheduler plans around real busy time. Mirrored events are read-only in Planner.
- `blockChanges`: events Planner wrote to Apple Calendar (task blocks and events created in Planner) that the user moved (`{ id, startAt, endAt }`) or deleted (`{ id, deleted: true }`) since the last sync.
- Response: `{ upserted, removed, blocks, rejected }`, where `blocks` are all events created in Planner in the window (task blocks and plain events) as the server now has them; the app makes its "Planner" calendar match.

When the apps are the calendar bridge, leave Google sync disconnected so events don't appear twice.

## Connect Google Calendar

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Calendar API**.
2. Configure the OAuth consent screen (External, add yourself as a test user), with the scope `https://www.googleapis.com/auth/calendar.events`.
3. Create an **OAuth client ID** of type *Web application*. Add the redirect URI `<PUBLIC_URL>/api/google/callback`, for example `http://localhost:8787/api/google/callback`.
4. Put the client ID and secret in `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, restart, then open Settings and choose **Connect Google Calendar**.

Planner syncs your primary calendar, from two weeks back to sixty days ahead. It pulls when you open the app (at most every five minutes) and when you press **Sync now**; changes made in Planner are written to Google immediately. If Google is unreachable, your change is kept locally and a banner tells you.

While the consent screen is in "Testing" mode, Google expires the connection after seven days. Publish the app (no review is needed for personal use with your own account) to keep it connected.

## Gmail inbox and replies to follow-ups

The iPhone and Mac apps have an **Inbox** tab: your Gmail Primary inbox from the last 30 days, grouped by person like Messages. You can read, reply, mark read, archive, and turn an email into a task or a "waiting on them" follow-up. People you're waiting on stay on top, and Planner marks a follow-up **Replied** (with the start of their email) when they write back. Replying to someone you're waiting on counts as chasing them: the follow-up moves two days on. It's separate from Google Calendar, so connecting it doesn't change where your calendar comes from.

1. In the same Google Cloud project, enable the **Gmail API** and add the scopes `https://www.googleapis.com/auth/gmail.modify` and `https://www.googleapis.com/auth/gmail.send` to the consent screen. Gmail uses the same client ID, secret and redirect URI as Calendar.
2. In the app, open **Inbox** and tap **Connect Gmail** (or use **Connect Gmail** in the web app's Settings). Google's sign-in sheet opens and brings you back to the app.

A connection made before replies were added is read-only; the Inbox offers **Reconnect Gmail** to upgrade it. Planner checks for replies every ten minutes and when you open the app, for follow-ups that have the person's email address. Text messages can't be read by any app on iOS, so replies by text still need a tap on **Got it**.

## Host it

Any host that runs a Docker container with a persistent disk works. For Fly.io:

```bash
fly launch --no-deploy --copy-config
```

```bash
fly volumes create planner_data --size 1
```

```bash
fly secrets set APP_PASSWORD=... MCP_TOKEN=... SESSION_SECRET=... PUBLIC_URL=https://YOUR-APP.fly.dev
```

```bash
fly deploy
```

Generate the token and secret with `openssl rand -base64 32`. Add `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` the same way, and register `https://YOUR-APP.fly.dev/api/google/callback` as a redirect URI.

In production the server refuses to start without `APP_PASSWORD`, `MCP_TOKEN` and `SESSION_SECRET`. Keep it to a single machine: the database is one file on one volume.

### Self-hosted on Proxmox with Tailscale

The running instance lives in an unprivileged Debian 12 LXC (container 109, `planner`) on a Proxmox host:

- Code in `/opt/planner`, owned by the `planner` system user; database in `/var/lib/planner/planner.db`.
- Config and secrets in `/etc/planner.env` (root, mode 600): `NODE_ENV`, `HOST=127.0.0.1`, `PORT`, `PUBLIC_URL`, `DATABASE_PATH`, `APP_PASSWORD`, `MCP_TOKEN`, `DEVICE_TOKEN`, `SESSION_SECRET`.
- systemd unit from `deploy/planner.service`. Update with `/opt/planner/deploy/update.sh` (pull, build, restart).
- Tailscale in the container, with two front doors:
  - `https://<host>.<tailnet>.ts.net:8443`: the web app and `/api`, tailnet only (`tailscale serve --https=8443`). This is `PUBLIC_URL` and the address the iOS and macOS apps use.
  - `https://<host>.<tailnet>.ts.net/mcp`: public through Tailscale Funnel on port 443, `/mcp` only, so claude.ai connectors (which call from Anthropic's cloud) can reach it. Every other path is 404 there, and `/mcp` requires `MCP_TOKEN`.
- Nightly `vzdump` snapshot of the container on the Proxmox host.

To connect Claude: claude.ai → Customize → Connectors → Add custom connector, URL `https://<host>.<tailnet>.ts.net/mcp`, no sign-in, request header `Authorization: Bearer <MCP_TOKEN>`. It then works on the web and in the mobile apps.

## How it is put together

```
src/shared/types.ts     shapes shared by server and UI
src/server/store.ts     SQLite (node:sqlite) tables for tasks, events, settings
src/server/scheduler.ts free-time search and block proposals (pure functions)
src/server/capture.ts   plain-language line -> task or event
src/server/google.ts    OAuth and two-way Google Calendar sync
src/server/device.ts    calendar mirror and block changes from the iOS/macOS apps
src/server/planner.ts   every operation; the API and MCP server both call this
src/server/api.ts       JSON API for the web app
src/server/mcp.ts       MCP tools
src/server/auth.ts      password login cookie, MCP and device bearer tokens
src/web/                React UI
```

## Known limits

- One user, one Google calendar (primary).
- Recurring events are shown as individual occurrences; editing one changes only that occurrence.
- Drag and drop needs a mouse. On a phone, tap a block to change its time, and use **Plan my tasks** to schedule.
- Capture is rule-based, not an LLM. Agents connected over MCP do their own language understanding and call the structured tools.
