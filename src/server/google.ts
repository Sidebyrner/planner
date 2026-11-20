import { DateTime } from 'luxon';
import type { CalEvent, GoogleStatus } from '../shared/types.js';
import type { Store } from './store.js';

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const API = 'https://www.googleapis.com/calendar/v3';
const SCOPE = 'https://www.googleapis.com/auth/calendar.events';
const CALENDAR = 'primary';
const DAY = 24 * 60 * 60 * 1000;

interface Tokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export interface GoogleConfig {
  clientId?: string;
  clientSecret?: string;
  redirectUri: string;
}

type FetchFn = typeof fetch;

/**
 * Two-way sync with the user's primary Google Calendar.
 *
 * Pull: events in a rolling window are mirrored into the local table, keyed by Google's id.
 * Push: anything created, moved or deleted in Planner is written through to Google.
 */
export class GoogleCalendar {
  constructor(
    private store: Store,
    private config: GoogleConfig,
    private fetchFn: FetchFn = fetch,
  ) {}

  get configured(): boolean {
    return !!(this.config.clientId && this.config.clientSecret);
  }

  get connected(): boolean {
    return this.configured && !!this.store.getValue<Tokens>('google_tokens');
  }

  status(): GoogleStatus {
    return {
      configured: this.configured,
      connected: this.connected,
      lastSyncAt: this.store.getValue<string>('google_last_sync'),
      error: this.store.getValue<string>('google_error'),
    };
  }

  authUrl(state: string): string {
    const params = new URLSearchParams({
      client_id: this.config.clientId!,
      redirect_uri: this.config.redirectUri,
      response_type: 'code',
      scope: SCOPE,
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
    this.saveTokens(data, data.refresh_token);
    this.store.setValue('google_error', null);
  }

  disconnect(): void {
    this.store.setValue('google_tokens', null);
    this.store.setValue('google_last_sync', null);
    this.store.setValue('google_error', null);
    // Mirrored Google events go away; things made in Planner stay, unlinked.
    this.store.db.prepare("DELETE FROM events WHERE source = 'google'").run();
    this.store.db.prepare('UPDATE events SET google_id = NULL').run();
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

  private saveTokens(data: any, refreshToken: string): Tokens {
    const tokens: Tokens = {
      accessToken: data.access_token,
      refreshToken,
      expiresAt: Date.now() + (data.expires_in ?? 3600) * 1000,
    };
    this.store.setValue('google_tokens', tokens);
    return tokens;
  }

  private async accessToken(): Promise<string> {
    let tokens = this.store.getValue<Tokens>('google_tokens');
    if (!tokens) throw new Error('Google Calendar is not connected.');
    if (tokens.expiresAt - 60_000 < Date.now()) {
      const data = await this.tokenRequest({ grant_type: 'refresh_token', refresh_token: tokens.refreshToken });
      tokens = this.saveTokens(data, tokens.refreshToken);
    }
    return tokens.accessToken;
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
