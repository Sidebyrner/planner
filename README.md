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

Tools: `get_agenda`, `list_tasks`, `create_task`, `update_task`, `delete_task`, `list_events`, `create_event`, `update_event`, `delete_event`, `find_free_slots`, `propose_schedule`, `apply_schedule`, `auto_schedule`, `capture`.

Then ask things like "what's on my plate today?", "add a 2-hour task to draft the winter menu, due Tuesday, and find time for it", or "I'm out Thursday afternoon, move my blocks".

The claude.ai and mobile apps add custom connectors through OAuth rather than a fixed bearer token, so this endpoint works with Claude Code and other clients that can send a header. Adding OAuth is the next step if you want it in those apps.

## Connect Google Calendar

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Calendar API**.
2. Configure the OAuth consent screen (External, add yourself as a test user), with the scope `https://www.googleapis.com/auth/calendar.events`.
3. Create an **OAuth client ID** of type *Web application*. Add the redirect URI `<PUBLIC_URL>/api/google/callback`, for example `http://localhost:8787/api/google/callback`.
4. Put the client ID and secret in `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, restart, then open Settings and choose **Connect Google Calendar**.

Planner syncs your primary calendar, from two weeks back to sixty days ahead. It pulls when you open the app (at most every five minutes) and when you press **Sync now**; changes made in Planner are written to Google immediately. If Google is unreachable, your change is kept locally and a banner tells you.

While the consent screen is in "Testing" mode, Google expires the connection after seven days. Publish the app (no review is needed for personal use with your own account) to keep it connected.

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

## How it is put together

```
src/shared/types.ts     shapes shared by server and UI
src/server/store.ts     SQLite (node:sqlite) tables for tasks, events, settings
src/server/scheduler.ts free-time search and block proposals (pure functions)
src/server/capture.ts   plain-language line -> task or event
src/server/google.ts    OAuth and two-way Google Calendar sync
src/server/planner.ts   every operation; the API and MCP server both call this
src/server/api.ts       JSON API for the web app
src/server/mcp.ts       MCP tools
src/server/auth.ts      password login cookie, MCP bearer token
src/web/                React UI
```

## Known limits

- One user, one Google calendar (primary).
- Recurring events are shown as individual occurrences; editing one changes only that occurrence.
- Drag and drop needs a mouse. On a phone, tap a block to change its time, and use **Plan my tasks** to schedule.
- Capture is rule-based, not an LLM. Agents connected over MCP do their own language understanding and call the structured tools.
