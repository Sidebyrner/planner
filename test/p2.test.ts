import { describe, expect, it } from 'vitest';
import { createApp } from '../src/server/app.js';
import { syncDevice } from '../src/server/device.js';

function makePlanner() {
  const { planner } = createApp({
    dbPath: ':memory:',
    auth: { secret: 'test', secureCookies: false },
    google: { clientId: undefined, clientSecret: undefined, redirectUri: 'x' },
  });
  planner.setSettings({ timezone: 'America/Detroit', workDays: [1, 2, 3, 4, 5, 6, 7], workStart: '00:00', workEnd: '23:59' });
  return planner;
}

const hoursAgo = (h: number) => new Date(Date.now() - h * 3600_000).toISOString();

async function pastBlock(planner: ReturnType<typeof makePlanner>, estimateMin: number, blockMin: number) {
  const task = planner.createTask({ title: 'Write proposal', estimateMin });
  const start = Date.now() - 3 * 3600_000;
  const [block] = await planner.apply([
    { taskId: task.id, startAt: new Date(start).toISOString(), endAt: new Date(start + blockMin * 60_000).toISOString() },
  ]);
  return { task, block };
}

describe('mark_block', () => {
  it('done takes the block off the estimate, and completes the task when nothing is left', async () => {
    const planner = makePlanner();
    const { task, block } = await pastBlock(planner, 120, 60);
    expect(planner.blocksToReview().map((b) => b.id)).toEqual([block.id]);

    const r = await planner.markBlock(block.id, 'done');
    expect(r.block.outcome).toBe('done');
    expect(r.tasks[0]).toMatchObject({ estimateMin: 60, status: 'todo' });
    expect(planner.blocksToReview()).toEqual([]);

    const second = await planner.apply([{ taskId: task.id, startAt: hoursAgo(2), endAt: hoursAgo(1) }]);
    const done = await planner.markBlock(second[0].id, 'done');
    expect(done.tasks[0].status).toBe('done');

    // Changing your mind gives the task back.
    const undone = await planner.markBlock(second[0].id, 'missed');
    expect(undone.tasks[0]).toMatchObject({ status: 'todo', estimateMin: 60 });
  });

  it('missed keeps the record and proposes new time for the work', async () => {
    const planner = makePlanner();
    const { task, block } = await pastBlock(planner, 60, 60);
    const r = await planner.markBlock(block.id, 'missed');
    expect(r.block.outcome).toBe('missed');
    expect(r.tasks[0]).toMatchObject({ id: task.id, estimateMin: 60, status: 'todo' });
    expect(r.replan!.blocks).toHaveLength(1);
    expect(Date.parse(r.replan!.blocks[0].startAt)).toBeGreaterThanOrEqual(Date.now() - 60_000);
    await expect(planner.markBlock(block.id, 'missed')).rejects.toThrow(/already/);
  });

  it('done on a Quick batch completes every task in it', async () => {
    const planner = makePlanner();
    const a = planner.createTask({ title: 'Reply to Ryan', estimateMin: 10 });
    const b = planner.createTask({ title: 'Pay invoice', estimateMin: 10 });
    const [batch] = await planner.apply([{ taskIds: [a.id, b.id], startAt: hoursAgo(2), endAt: hoursAgo(1.5) }]);
    const r = await planner.markBlock(batch.id, 'done');
    expect(r.tasks.map((t) => t.status)).toEqual(['done', 'done']);
  });

  it('refuses events that are not task blocks', async () => {
    const planner = makePlanner();
    const e = await planner.createEvent({ title: 'Lunch', startAt: hoursAgo(2), endAt: hoursAgo(1) });
    await expect(planner.markBlock(e.id, 'done')).rejects.toThrow(/task blocks/);
  });
});

describe('calendar sources', () => {
  it('reports the device calendar as the source once a device has synced', async () => {
    const planner = makePlanner();
    expect(planner.calendarSources()).toMatchObject({ sourceOfTruth: 'none', device: { lastSyncAt: null } });
    await syncDevice(planner, { from: hoursAgo(24), to: hoursAgo(-24), events: [] });
    const s = planner.calendarSources();
    expect(s.sourceOfTruth).toBe('device');
    expect(s.device.minutesAgo).toBe(0);
    expect(s.google.connected).toBe(false);
  });
});
