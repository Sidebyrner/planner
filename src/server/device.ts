import { z } from 'zod';
import type { CalEvent } from '../shared/types.js';
import { NotFound, type Planner } from './planner.js';
import { iso } from './store.js';

const when = z.string().refine((v) => !Number.isNaN(Date.parse(v)), 'Not a valid date');

/**
 * One sync from the iOS or macOS app.
 *
 * events: everything on the device's calendars inside [from, to), except the
 *   "Planner" calendar the app writes task blocks into. Replaces the previous
 *   mirror for that window, so the scheduler sees real busy time.
 * blockChanges: Planner events (task blocks and events created in Planner) the
 *   user moved or deleted in Apple Calendar since the last sync. The app knows
 *   because it remembers which ones it wrote.
 *
 * The response lists the Planner events in the window as the server now has
 * them (`blocks`, named for task blocks, which came first); the app makes the
 * Planner calendar match it.
 */
export const DeviceSync = z.object({
  from: when,
  to: when,
  events: z
    .array(
      z.object({
        // For recurring events, the app sends an id per occurrence (identifier + start).
        externalId: z.string().min(1).max(500),
        title: z.string().max(500),
        notes: z.string().max(5000).optional(),
        startAt: when,
        endAt: when,
        allDay: z.boolean().optional(),
      }),
    )
    .max(5000),
  blockChanges: z
    .array(
      z.union([
        z.object({ id: z.string(), deleted: z.literal(true) }),
        z.object({ id: z.string(), startAt: when, endAt: when }),
      ]),
    )
    .max(1000)
    .optional(),
});

export type DeviceSyncInput = z.infer<typeof DeviceSync>;

export interface DeviceSyncResult {
  upserted: number;
  removed: number;
  /** Events created in Planner, task blocks and plain events alike. */
  blocks: CalEvent[];
  /** Block changes that could not be applied, with the reason. */
  rejected: { id: string; reason: string }[];
}

export async function syncDevice(planner: Planner, input: DeviceSyncInput): Promise<DeviceSyncResult> {
  const { store } = planner;
  const from = iso(input.from);
  const to = iso(input.to);
  if (to <= from) throw new Error('The sync window must end after it starts.');

  // Mirror device events. Done in one transaction so a half-applied sync never shows.
  const seen = new Set<string>();
  let upserted = 0;
  let removed = 0;
  store.db.exec('BEGIN');
  try {
    for (const e of input.events) {
      const startAt = iso(e.startAt);
      const endAt = iso(e.endAt);
      if (endAt <= startAt || seen.has(e.externalId)) continue;
      seen.add(e.externalId);
      const fields = { title: e.title || '(no title)', notes: e.notes ?? '', startAt, endAt, allDay: !!e.allDay };
      const existing = store.getEventByExternalId('device', e.externalId);
      if (existing) store.updateEvent(existing.id, fields);
      else store.createEvent({ ...fields, externalId: e.externalId, source: 'device' });
      upserted++;
    }
    for (const e of store.listEvents({ from, to })) {
      if (e.source === 'device' && !seen.has(e.externalId!)) {
        store.deleteEvent(e.id);
        removed++;
      }
    }
    store.db.exec('COMMIT');
  } catch (err) {
    store.db.exec('ROLLBACK');
    throw err;
  }

  // Apply what the user did in Apple Calendar to events Planner wrote there.
  const rejected: DeviceSyncResult['rejected'] = [];
  for (const c of input.blockChanges ?? []) {
    const block = store.getEvent(c.id);
    if (!block) continue; // already gone: nothing to do
    if (block.source !== 'local') {
      rejected.push({ id: c.id, reason: 'Not an event created in Planner.' });
      continue;
    }
    try {
      if ('deleted' in c) await planner.deleteEvent(c.id);
      else await planner.updateEvent(c.id, { startAt: c.startAt, endAt: c.endAt });
    } catch (err) {
      if (err instanceof NotFound) continue;
      rejected.push({ id: c.id, reason: (err as Error).message });
    }
  }

  // Only Planner's own events: device events came from the device, and Google
  // events reach the device through the Google account itself.
  const blocks = store.listEvents({ from, to }).filter((e) => e.source === 'local');
  store.setValue('device_last_sync', { at: new Date().toISOString(), from, to, events: upserted });
  return { upserted, removed, blocks, rejected };
}
