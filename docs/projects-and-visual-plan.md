# Projects, visual refresh, and scheduling that fits a shift-based week

> **Status: built** (all four parts in one round). Differences from the outline below:
> - Waiting-on is captured with `@Name` rather than guessed from words like "ask"; `#tag` files a task under a project and an unknown tag creates one.
> - Project windows can also come from existing calendar events (`hostMatch`): events whose title contains the text become that project's time instead of busy time.
> - Errand grouping by place was left out; widgets are deferred (App Groups need the paid developer program).
> - The web app got the same projects, checklist, waiting-on and colours, plus a dark mode.

## Context

Planner now runs end to end: server on Proxmox, a Mac app that bridges Apple Calendar, an iPhone app, and Claude connected through MCP. Using it shows what's missing for a week that is built around fixed work shifts, with several streams of work in between (a day job, freelance clients, a job search, home, fitness, family and friends):

- Every task is one flat list. There is no way to say which stream it belongs to, see a stream at a glance, or ask Claude about one.
- Tasks can't be edited in the apps (only completed or deleted), and many real tasks are short checklists written into notes.
- A lot of tasks are asks of other people ("remind X to…", "ask Y about…"). They need a follow-up date, not a time block, but today the scheduler books time for them.
- The scheduler only knows working hours. It can't keep job-search work in the early-morning block, or freelance work off shift days, and it gives every 15-minute task its own block.
- The apps are functional but plain: no colour, no "what's next" view, no widgets or reminders.

## Approach

Add **projects** first, because colour, filters, time windows and better MCP answers all build on them. Then make tasks editable and richer, teach the scheduler about per-project windows and batching, and use all of that in a visual refresh. Each phase ships on its own: server + tests, then MCP, then apps, deployed with `deploy/update.sh`.

The scheduler (`src/server/scheduler.ts`) stays a set of pure functions; new behaviour comes in as extra inputs, with tests next to the existing ones.

## Phase 1 — Projects

- **Model** (`store.ts`, `shared/types.ts`): `Project { id, name, color, emoji, archived, sortOrder }`; `Task.projectId`; `CalEvent.projectId` (task blocks take their task's project; plain events can have one). Migration adds the table and nullable columns.
- **Capture** (`capture.ts`): `#name` anywhere in a line assigns a project, matched case-insensitively by name or prefix. An unknown `#tag` shows "new project" in the preview and is created on save.
- **API**: `GET/POST/PATCH /api/projects`, `projectId` on task and event create/patch, projects included in `/api/state`.
- **MCP** (`mcp.ts`): `list_projects`, `create_project`, `update_project`; `project` (name or id) accepted by `create_task`, `update_task`, `capture`, `list_tasks`; `get_agenda` groups open tasks by project.
- **Apps**: project chip and colour on task rows; filter bar (All / each project / No project); Mac sidebar section listing projects with open-task count and hours booked this week; blocks in the calendar grid coloured by project.
- **Apple Calendar**: blocks keep plain titles; the project name goes in the event notes so it's searchable without cluttering the calendar.
- **Tests**: capture `#tag` parsing, project CRUD, filtering, MCP tools accepting names.

## Phase 2 — Editable tasks, checklists, waiting-on

- **Task detail sheet** in both apps: title, notes, project, estimate, due, priority, status. Opened by tapping a row (iPhone) or selecting it (Mac).
- **Checklists**: `Task.checklist: { id, text, done }[]`. Notes written as numbered or `-` lists can be turned into a checklist with one tap; MCP gets `set_checklist` / `check_item`. Progress ("2/5") shows on the row.
- **Waiting-on**: new status `waiting` with `waitingOn` (person) and `followUpAt`. Waiting tasks are never scheduled; they show in their own list sorted by follow-up date, and come back to `todo` (and to the top of the list) on that date. Capture: `ask Sam about the invoice` → suggests waiting-on (confirm in preview). MCP: `list_waiting`.
- **Tests**: status transitions, scheduler ignores waiting tasks, follow-up resurfacing.

## Phase 3 — Scheduling that fits the week

- **Project time windows**: each project can have preferred windows (weekday set + start/end, e.g. "weekdays 06:45–08:15"). The scheduler places that project's tasks inside its windows first and falls back to general working hours only when allowed (`windowStrict` per project). Proposals say which tasks fell back.
- **Quick-task batching**: open tasks of ≤15 min in the same project are proposed as one combined block ("Quick: 4 tasks") instead of separate ones; booking it links all of them, and finishing them all releases the block.
- **Buffers**: optional minutes kept free before and after long fixed events (shifts, travel), set in Settings.
- **Errand grouping** (smaller, optional): `Task.place`; tasks with the same place are proposed back to back.
- **Tests**: window placement and fallback, batching and release, buffers around mirrored events.

## Phase 4 — Visual refresh

- **Today view** (default tab on iPhone, top of the Mac sidebar): "Now" and "Next" cards with time left, today's timeline, due today/overdue, waiting-on follow-ups due, and the capture bar.
- **Calendar**: project colours and emoji, a details sheet on tap, drag to move and resize Planner blocks on the Mac (sent as an event patch), a compact 3-day view on iPhone landscape.
- **Look and feel**: a small colour palette for projects that works in light and dark mode, consistent spacing and type scale, an app icon, empty states that teach the capture syntax.
- **Reminders**: local notifications at block start ("Time for: …") and for follow-ups, scheduled by each device from the synced state; a setting to turn them off.
- **Widgets** (WidgetKit, iPhone home/lock screen and Mac): "Next up" and "Today". Needs an App Group so the widget can read the app's cached state; check that a free Apple ID allows it before building.

## Phase 5 — Assistant (MCP) upgrades

- `plan_week`: propose blocks for the coming week using windows and batching, and return a summary per project (hours booked, tasks that didn't fit) so Claude can talk it through before booking.
- `weekly_review`: done this week by project, overdue, waiting-on due, unscheduled, and how booked hours compare with the windows.
- `get_project`: one project's open tasks, booked blocks, waiting-on items and recent completions.
- Tool descriptions updated so Claude uses projects, checklists and waiting-on instead of putting everything into titles and notes.

## Verification (each phase)

- `npm test` and `swift test` pass with the new tests; `xcodebuild` succeeds for macOS and the iOS simulator.
- Deployed with `deploy/update.sh`; `/healthz` ok on the tailnet and `/mcp` still 401 without the token publicly.
- Manual: the phase's feature works in the Mac app, the iPhone app and through Claude.

## Not in scope

- Multi-user or sharing.
- A second scheduler in the apps; the server stays the source of truth.
- Writing to Google Calendar directly (it's reached through the Planner calendar on the Mac).
