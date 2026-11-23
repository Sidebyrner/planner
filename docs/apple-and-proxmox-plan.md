# Planner for iOS and macOS

## Context

The web Planner MVP is done and pushed to `Sidebyrner/planner` (`main`): a Node server with SQLite, a scheduler, plain-language capture, Google sync, and an MCP endpoint with 14 tools. You now want native iOS and macOS apps on your new Mac, with an assistant keeping track of your work and placing tasks and events on your calendar. You chose **both** data paths: Apple Calendar on the device, plus the Planner server so remote agents can reach everything.

Two facts shape the plan:

- **This cloud session cannot build Apple apps or reach your Mac.** There is no Xcode here, and `Connors-MacBook-Pro / coding_projects` is listed but not offered to cloud sessions. The build has to run in a Claude Code session started on the Mac itself.
- **I could not verify "Claude Duet".** A web search found no product by that name, so I do not know how it connects to tools. The plan uses MCP, which every Claude product supports, and confirms the Duet connection as its own step before wiring it.

## Approach

The server stays the single source of truth for tasks and scheduling. The native apps are its front end and its bridge to Apple Calendar. This reuses the scheduler, capture parser and MCP tools that already exist and are tested, and avoids writing a second scheduler in Swift or running two sync systems (iCloud and server) that can disagree.

```
Apple Calendar (EventKit) <-> native app <-> Planner server <-> MCP <-> assistant
   incl. Google accounts       iOS/macOS      tasks, scheduler
   added in System Settings                   SQLite
```

- The app uploads your device calendar events (rolling window) to the server so the scheduler sees real busy time.
- Blocks the server books (by you or by an agent) are written by the app into a dedicated "Planner" calendar in Apple Calendar.
- With the device as the calendar bridge, the server's own Google sync is left off, to avoid duplicate events.

## Steps

### 0. Set up the Mac (local session, your approval on each command)
- Install Xcode from the App Store, then command line tools; Homebrew; Node 22; `xcodegen` (same tool House Pour uses).
- Clone `Sidebyrner/planner` into `coding_projects`, run `npm install`, `npm test`, `npm run build`, `npm start`, and confirm http://localhost:8787 works.

### 1. Server additions (`src/server/`)
- `auth.ts`, `api.ts`: accept a bearer device token on `/api` alongside the login cookie, so the apps can sign in.
- `store.ts`, `shared/types.ts`: add event source `device` and a stable external id column.
- `planner.ts`, `api.ts`: `PUT /api/device/events` replaces the mirrored device events for a window and returns the task blocks the app should write to Apple Calendar; reuses `Store.listEvents` and the existing upsert/delete-missing pattern from `google.ts` `pull()`.
- `test/app.test.ts`: cover token auth, mirror upsert/removal, and that proposals avoid mirrored events.

### 2. Shared Swift package (`apple/PlannerKit/`)
- Models matching `src/shared/types.ts` (Task, CalEvent, Settings, ScheduleProposal, Captured).
- `PlannerAPI`: async client for the existing endpoints (`/state`, `/tasks`, `/events`, `/capture`, `/schedule/propose`, `/schedule/apply`).
- `CalendarBridge`: EventKit permission, read events in window, create/update/remove blocks in the "Planner" calendar.
- `SyncEngine`: upload device events, apply returned blocks, refresh state; last state cached on disk for offline viewing.
- Unit tests with a stubbed HTTP layer and an in-memory calendar store.

### 3. SwiftUI app (`apple/Planner/`, one multiplatform target, iOS 17 / macOS 14)
- Capture bar with the live preview from `/api/capture`.
- Task list (open, done, due, estimate, priority, next block).
- Calendar: week grid on Mac, day view on iPhone; proposed blocks shown dashed, with Book and Discard.
- Settings: server address, token, working hours, calendar permission, which calendars count as busy.
- `apple/project.yml` for xcodegen, with the calendar usage description strings.

### 4. Host the server on Proxmox (done first, right after step 0)
Run from the Mac session over SSH to the Proxmox host; every command is shown for approval, and nothing existing on the host is changed.
- Look first, change nothing: `pveversion`, `pct list`, `pvesm status`, available templates and bridges, to pick a free container ID, storage and network.
- Create an unprivileged Debian 12 LXC (1 core, 512 MB RAM, 4 GB disk, DHCP on the main bridge, start on boot).
- Inside it: install Node 22 and git, clone `Sidebyrner/planner` to `/opt/planner`, `npm ci`, `npm run build`.
- Config in `/etc/planner.env` (mode 600): `NODE_ENV=production`, generated `APP_PASSWORD`, `MCP_TOKEN`, `SESSION_SECRET`, `DATABASE_PATH=/var/lib/planner/planner.db`, `PUBLIC_URL`.
- A `planner` system user and a systemd unit that runs `node dist/server/index.js` and restarts on failure. Add `deploy/planner.service` and `deploy/update.sh` (pull, build, restart) to the repo.
- Tailscale inside the LXC (needs the TUN device enabled in the container config), then `tailscale serve` for an HTTPS address on your tailnet; set `PUBLIC_URL` to it. You approve the Tailscale login link.
- Install Tailscale on the Mac and iPhone, signed into the same account.
- Limit of this choice: only devices on your tailnet can reach Planner. An assistant running in Anthropic's cloud cannot call the MCP endpoint; one running on your Mac can. If Duet turns out to be cloud-hosted, the fix is a Cloudflare Tunnel for `/mcp` only.
- Backups: a nightly Proxmox snapshot or `vzdump` job for the container.

### 5. Connect the assistant
- Confirm what Claude Duet is and how it adds tools (you show me its settings or docs).
- If it takes a remote MCP server with a header: point it at `/mcp` with the bearer token, no code needed.
- If it requires OAuth connectors (as claude.ai and the mobile apps do): add OAuth to `src/server/mcp.ts` / `auth.ts`.

## What you need
- An Apple ID signed into Xcode. A free account runs the Mac app, the simulator, and 7-day builds on your iPhone. The paid Apple Developer Program ($99/year) is only needed for TestFlight or builds that don't expire.
- SSH access from the Mac to the Proxmox host (hostname or IP, and a user allowed to run `pct`), and a Tailscale account.

## Verification
- `npm test` passes, including the new device-sync tests.
- `swift test` passes in `apple/PlannerKit`.
- `xcodebuild` succeeds for the macOS and iOS simulator destinations.
- On the Mac: grant calendar access, see real events in the app, capture a task, plan, book; the block appears in Apple Calendar's "Planner" calendar; delete it there and it disappears from the app after sync.
- In the iOS simulator: same flow against the local server.
- Through MCP: `create_task` then `auto_schedule` from an agent; the block shows up in the Mac app and Apple Calendar.
- Proxmox: `systemctl status planner` is active, `curl` to `/healthz` over the tailnet address returns ok from the Mac, the login page loads on the iPhone over Tailscale, and the service comes back after a container reboot.

## How this gets executed
Order: 0 (Mac setup), 4 (Proxmox), 1 (server additions), 2 and 3 (apps), 5 (assistant).

Everything except step 1 needs a Claude Code session running on the Mac: a cloud session has no Xcode, no route to the home network and none of the SSH keys. The local session asks before each command, including every SSH command to Proxmox.

Step 1 is being done in the cloud session that wrote this plan. Run `git pull` before starting it; if `src/server/device.ts` exists, step 1 is done.
