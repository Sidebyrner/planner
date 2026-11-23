import { createHmac } from 'node:crypto';
import type { BlockDetail, Planner } from './planner.js';

export interface WebhookConfig {
  url: string;
  /** Signs each body: header X-Planner-Signature: sha256=<hex HMAC>. */
  secret?: string;
  /** How often to look for blocks that just started. Default 30 s. */
  intervalMs?: number;
  fetchFn?: typeof fetch;
}

export interface BlockStarted extends BlockDetail {
  type: 'block.started';
  sentAt: string;
}

const LAST_CHECK = 'webhook_last_check';
/** After downtime, only announce blocks that started this recently; older nudges are no use. */
const MAX_CATCH_UP_MS = 5 * 60_000;

/**
 * Announce each task block as it starts, so a nudge can go out on time
 * ("Step 2 of 5: tape the trim, 30 min"). The URL comes from the server's
 * environment, never from settings an agent can change.
 */
export class BlockWatcher {
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly planner: Planner,
    private readonly config: WebhookConfig,
  ) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick().catch((err) => console.error('Block webhook failed:', err)), this.config.intervalMs ?? 30_000);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Send block.started for every block that began since the last check. Returns what was sent. */
  async tick(now = new Date()): Promise<BlockStarted[]> {
    const { store } = this.planner;
    const t = now.getTime();
    const last = store.getValue<string>(LAST_CHECK);
    const since = Math.max(last ? Date.parse(last) : t - 60_000, t - MAX_CATCH_UP_MS);
    store.setValue(LAST_CHECK, now.toISOString());

    const started = store
      .listEvents({ from: now.toISOString(), to: new Date(t + 1).toISOString() })
      .filter((e) => (e.taskId || e.taskIds.length) && Date.parse(e.startAt) > since && Date.parse(e.startAt) <= t);

    const sent: BlockStarted[] = [];
    for (const block of started) {
      const payload: BlockStarted = { type: 'block.started', sentAt: now.toISOString(), ...this.planner.blockDetail(block, t) };
      const body = JSON.stringify(payload);
      const headers: Record<string, string> = { 'content-type': 'application/json', 'user-agent': 'planner-webhook' };
      if (this.config.secret) headers['x-planner-signature'] = `sha256=${createHmac('sha256', this.config.secret).update(body).digest('hex')}`;
      const res = await (this.config.fetchFn ?? fetch)(this.config.url, { method: 'POST', headers, body });
      if (!res.ok) console.error(`Block webhook got HTTP ${res.status} for block ${block.id}`);
      sent.push(payload);
    }
    return sent;
  }
}
