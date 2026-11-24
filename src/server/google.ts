import { DateTime } from 'luxon';
import type { CalEvent, GmailStatus, GoogleStatus } from '../shared/types.js';
import type { Store } from './store.js';

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const API = 'https://www.googleapis.com/calendar/v3';
const SCOPE = 'https://www.googleapis.com/auth/calendar.events';
const GMAIL_API = 'https://gmail.googleapis.com/gmail/v1/users/me';
// Read, mark read and archive (modify), and reply (send). Older connections may have read-only.
const GMAIL_SCOPE = 'https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send';
const CALENDAR = 'primary';
const DAY = 24 * 60 * 60 * 1000;

interface Tokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  /** What Google granted, space-separated. Missing on connections made before it was kept. */
  scope?: string;
}

export interface GoogleConfig {
  clientId?: string;
  clientSecret?: string;
  redirectUri: string;
}

type FetchFn = typeof fetch;

/**
 * Sign-in to one Google service, with its own tokens. Calendar and Gmail are connected
 * separately, so turning on reply checks never changes where the calendar comes from.
 */
class GoogleAccount {
  constructor(
    protected store: Store,
    protected config: GoogleConfig,
    protected fetchFn: FetchFn,
    private tokenKey: string,
    private scope: string,
    private errorKey: string,
  ) {}

  get configured(): boolean {
    return !!(this.config.clientId && this.config.clientSecret);
  }

  get connected(): boolean {
    return this.configured && !!this.store.getValue<Tokens>(this.tokenKey);
  }

  authUrl(state: string): string {
    const params = new URLSearchParams({
      client_id: this.config.clientId!,
      redirect_uri: this.config.redirectUri,
      response_type: 'code',
      scope: this.scope,
      access_type: 'offline',
      prompt: 'consent',
      state,
    });
    return `${AUTH_URL}?${params}`;
  }

  async exchangeCode(code: string): Promise<void> {
    const data = await this.tokenRequest({
      code,
      grant_type: 'authorization_code',
      redirect_uri: this.config.redirectUri,
    });
    if (!data.refresh_token) throw new Error('Google did not return a refresh token. Remove Planner under your Google account permissions and connect again.');
    this.saveTokens(data, data.refresh_token, data.scope);
    this.store.setValue(this.errorKey, null);
  }

  /** The scopes Google granted, as recorded at sign-in. */
  protected grantedScope(): string {
    return this.store.getValue<Tokens>(this.tokenKey)?.scope ?? '';
  }

  protected clearTokens(): void {
    this.store.setValue(this.tokenKey, null);
  }

  private async tokenRequest(body: Record<string, string>): Promise<any> {
    const res = await this.fetchFn(TOKEN_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: this.config.clientId!,
        client_secret: this.config.clientSecret!,
        ...body,
      }),
    });
    const data: any = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`Google sign-in failed: ${data.error_description || data.error || res.status}`);
    return data;
  }

  private saveTokens(data: any, refreshToken: string, scope?: string): Tokens {
    const tokens: Tokens = {
      accessToken: data.access_token,
      refreshToken,
      expiresAt: Date.now() + (data.expires_in ?? 3600) * 1000,
      scope: data.scope ?? scope,
    };
    this.store.setValue(this.tokenKey, tokens);
    return tokens;
  }

  protected async accessToken(): Promise<string> {
    let tokens = this.store.getValue<Tokens>(this.tokenKey);
    if (!tokens) throw new Error('Google is not connected.');
    if (tokens.expiresAt - 60_000 < Date.now()) {
      const data = await this.tokenRequest({ grant_type: 'refresh_token', refresh_token: tokens.refreshToken });
      tokens = this.saveTokens(data, tokens.refreshToken, tokens.scope);
    }
    return tokens.accessToken;
  }
}

/**
 * Two-way sync with the user's primary Google Calendar.
 *
 * Pull: events in a rolling window are mirrored into the local table, keyed by Google's id.
 * Push: anything created, moved or deleted in Planner is written through to Google.
 */
export class GoogleCalendar extends GoogleAccount {
  constructor(store: Store, config: GoogleConfig, fetchFn: FetchFn = fetch) {
    super(store, config, fetchFn, 'google_tokens', SCOPE, 'google_error');
  }

  status(): GoogleStatus {
    return {
      configured: this.configured,
      connected: this.connected,
      lastSyncAt: this.store.getValue<string>('google_last_sync'),
      error: this.store.getValue<string>('google_error'),
    };
  }

  disconnect(): void {
    this.clearTokens();
    this.store.setValue('google_last_sync', null);
    this.store.setValue('google_error', null);
    // Mirrored Google events go away; things made in Planner stay, unlinked.
    this.store.db.prepare("DELETE FROM events WHERE source = 'google'").run();
    this.store.db.prepare('UPDATE events SET google_id = NULL').run();
  }

  private async api(method: string, path: string, body?: unknown): Promise<any> {
    const res = await this.fetchFn(`${API}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${await this.accessToken()}`,
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 204) return null;
    const data: any = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = new Error(`Google Calendar: ${data?.error?.message || res.status}`) as Error & { status: number };
      err.status = res.status;
      throw err;
    }
    return data;
  }

  private toGoogle(e: CalEvent): Record<string, unknown> {
    const zone = this.store.getSettings().timezone;
    const body: Record<string, unknown> = { summary: e.title, description: e.notes || undefined };
    if (e.allDay) {
      body.start = { date: DateTime.fromISO(e.startAt, { zone }).toISODate() };
      body.end = { date: DateTime.fromISO(e.endAt, { zone }).toISODate() };
    } else {
      body.start = { dateTime: e.startAt };
      body.end = { dateTime: e.endAt };
    }
    if (e.taskId) body.extendedProperties = { private: { plannerTaskId: e.taskId } };
    return body;
  }

  /** Create or update the Google copy of a local event. Returns Google's event id. */
  async push(e: CalEvent): Promise<string> {
    const path = `/calendars/${CALENDAR}/events`;
    if (e.googleId) {
      await this.api('PATCH', `${path}/${encodeURIComponent(e.googleId)}`, this.toGoogle(e));
      return e.googleId;
    }
    const created = await this.api('POST', path, this.toGoogle(e));
    return created.id;
  }

  async remove(googleId: string): Promise<void> {
    try {
      await this.api('DELETE', `/calendars/${CALENDAR}/events/${encodeURIComponent(googleId)}`);
    } catch (err: any) {
      if (err.status !== 404 && err.status !== 410) throw err; // already gone is fine
    }
  }

  /** Mirror Google into the local table for a rolling window around today. */
  async pull(now = new Date()): Promise<{ upserted: number; removed: number }> {
    const zone = this.store.getSettings().timezone;
    const timeMin = new Date(now.getTime() - 14 * DAY).toISOString();
    const timeMax = new Date(now.getTime() + 60 * DAY).toISOString();
    const seen = new Set<string>();
    let upserted = 0;
    let pageToken: string | undefined;

    do {
      const params = new URLSearchParams({ timeMin, timeMax, singleEvents: 'true', maxResults: '250' });
      if (pageToken) params.set('pageToken', pageToken);
      const page = await this.api('GET', `/calendars/${CALENDAR}/events?${params}`);
      for (const g of page.items ?? []) {
        if (g.status === 'cancelled' || !g.start || !g.end) continue;
        const allDay = !!g.start.date;
        const startAt = allDay ? DateTime.fromISO(g.start.date, { zone }).toUTC().toISO()! : new Date(g.start.dateTime).toISOString();
        const endAt = allDay ? DateTime.fromISO(g.end.date, { zone }).toUTC().toISO()! : new Date(g.end.dateTime).toISOString();
        if (endAt <= startAt) continue;
        seen.add(g.id);
        const fields = { title: g.summary || '(no title)', notes: g.description ?? '', startAt, endAt, allDay };
        const existing = this.store.getEventByGoogleId(g.id);
        if (existing) {
          this.store.updateEvent(existing.id, fields);
        } else {
          this.store.createEvent({ ...fields, googleId: g.id, source: 'google' });
        }
        upserted++;
      }
      pageToken = page.nextPageToken;
    } while (pageToken);

    // Anything linked to Google inside the window that Google no longer lists was deleted there.
    let removed = 0;
    for (const e of this.store.listEvents({ from: timeMin, to: timeMax })) {
      if (e.googleId && !seen.has(e.googleId)) {
        this.store.deleteEvent(e.id);
        removed++;
      }
    }
    this.store.setValue('google_last_sync', now.toISOString());
    this.store.setValue('google_error', null);
    return { upserted, removed };
  }
}

export interface Reply {
  at: string;
  snippet: string;
}

/**
 * Gmail for the inbox: list and read threads, reply, mark read and archive, and notice when
 * someone you're waiting on has emailed back. Planner keeps no mail beyond a short snippet.
 */
export class Gmail extends GoogleAccount {
  constructor(store: Store, config: GoogleConfig, fetchFn: FetchFn = fetch) {
    super(store, config, fetchFn, 'gmail_tokens', GMAIL_SCOPE, 'gmail_error');
  }

  status(): GmailStatus {
    return {
      configured: this.configured,
      connected: this.connected,
      lastCheckAt: this.store.getValue<string>('gmail_last_check'),
      error: this.store.getValue<string>('gmail_error'),
      canReply: this.canReply,
    };
  }

  /** Connected with permission to send and change labels (not an older read-only sign-in). */
  get canReply(): boolean {
    const scope = this.grantedScope();
    return this.connected && scope.includes('gmail.send') && scope.includes('gmail.modify');
  }

  disconnect(): void {
    this.clearTokens();
    this.store.setValue('gmail_me', null);
    this.store.setValue('gmail_last_check', null);
    this.store.setValue('gmail_error', null);
  }

  private async request(method: string, path: string, body?: unknown): Promise<any> {
    const res = await this.fetchFn(`${GMAIL_API}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${await this.accessToken()}`,
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data: any = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`Gmail: ${data?.error?.message || res.status}`);
    return data;
  }

  private get(path: string): Promise<any> {
    return this.request('GET', path);
  }

  /** The signed-in address, remembered after the first look. */
  async myEmail(): Promise<string> {
    const saved = this.store.getValue<string>('gmail_me');
    if (saved) return saved;
    const profile = await this.get('/profile');
    const email = String(profile.emailAddress ?? '').toLowerCase();
    this.store.setValue('gmail_me', email);
    return email;
  }

  async listThreadIds(q: string, max = 50): Promise<string[]> {
    const list = await this.get(`/threads?${new URLSearchParams({ q, maxResults: String(max) })}`);
    return (list.threads ?? []).map((t: any) => String(t.id));
  }

  async getThread(id: string, format: 'metadata' | 'full'): Promise<any> {
    const params = new URLSearchParams({ format });
    if (format === 'metadata') for (const h of ['From', 'To', 'Subject', 'Date', 'Message-ID', 'References']) params.append('metadataHeaders', h);
    return this.get(`/threads/${encodeURIComponent(id)}?${params}`);
  }

  async send(raw: string, threadId: string): Promise<any> {
    return this.request('POST', '/messages/send', { raw, threadId });
  }

  async modifyThread(id: string, removeLabelIds: string[]): Promise<void> {
    await this.request('POST', `/threads/${encodeURIComponent(id)}/modify`, { removeLabelIds });
  }

  /** The newest email from `email` received after `since`, if any. */
  async findReply(email: string, since: string): Promise<Reply | null> {
    const after = Math.floor(Date.parse(since) / 1000);
    const q = `from:${email} after:${after}`;
    const list = await this.get(`/messages?${new URLSearchParams({ q, maxResults: '1' })}`);
    const id = list.messages?.[0]?.id;
    if (!id) return null;
    const msg = await this.get(`/messages/${encodeURIComponent(id)}?format=metadata&metadataHeaders=Subject`);
    const at = msg.internalDate ? new Date(Number(msg.internalDate)).toISOString() : new Date().toISOString();
    // Gmail's search is by day; drop anything from before the wait actually began.
    if (Date.parse(at) < Date.parse(since)) return null;
    return { at, snippet: decodeEntities(String(msg.snippet ?? '')).slice(0, 280) };
  }
}

export function decodeEntities(text: string): string {
  return text
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}
