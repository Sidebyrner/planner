import { DateTime } from 'luxon';
import type { InboxConversation, InboxMessage, InboxPerson, InboxThread, Task } from '../shared/types.js';
import { decodeEntities, type Gmail } from './google.js';
import type { Planner } from './planner.js';

const PRIMARY = 'in:inbox category:primary newer_than:30d';
const CACHE_MS = 60_000;

export class GmailNotConnected extends Error {
  constructor() {
    super('Gmail is not connected. Connect it from the Inbox in the app or from Settings.');
  }
}

interface Address {
  name: string;
  email: string;
}

/** "Sam Rivera <sam@x.com>" → { name, email }. */
export function parseAddress(value: string): Address {
  const v = value.trim();
  const angle = /^(.*?)<([^>]+)>\s*$/.exec(v);
  if (angle) {
    const name = angle[1].trim().replace(/^"(.*)"$/, '$1').trim();
    const email = angle[2].trim().toLowerCase();
    return { name: name || email.split('@')[0], email };
  }
  const email = v.replace(/^mailto:/i, '').toLowerCase();
  return { name: email.split('@')[0], email };
}

const header = (msg: any, name: string): string =>
  String((msg.payload?.headers ?? []).find((h: any) => String(h.name).toLowerCase() === name.toLowerCase())?.value ?? '');

const base64url = (data: string): string => Buffer.from(data.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');

function findPart(part: any, mime: string): string | null {
  if (!part) return null;
  if (part.mimeType === mime && part.body?.data) return base64url(part.body.data);
  for (const child of part.parts ?? []) {
    const found = findPart(child, mime);
    if (found) return found;
  }
  return null;
}

function htmlToText(html: string): string {
  return decodeEntities(
    html
      .replace(/<(style|script)[\s\S]*?<\/\1>/gi, '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/(p|div|li|tr|h\d)>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' '),
  );
}

/** The part of an email worth reading: no quoted history, no signature. */
export function cleanBody(text: string): string {
  let t = text.replace(/\r\n/g, '\n');
  // "On Tue, Nov 24, 2026 at 9:00 AM Sam <sam@x.com> wrote:" (sometimes wrapped over two lines).
  const quote = /\n[^\n]*\bOn\b[^\n]{0,200}(\n[^\n]{0,200})?\bwrote:\s*\n/.exec('\n' + t);
  if (quote) t = ('\n' + t).slice(0, quote.index);
  const lines: string[] = [];
  for (const line of t.split('\n')) {
    if (/^\s*--\s*$/.test(line)) break; // signature delimiter
    if (/^\s*-{2,}\s*Original Message\s*-{2,}/i.test(line)) break;
    if (/^\s*>/.test(line)) continue;
    if (/^\s*Sent from my (iPhone|iPad|Android|phone)/i.test(line)) continue;
    lines.push(line.replace(/\s+$/, ''));
  }
  return lines.join('\n').replace(/\n{3,}/g, '\n\n').trim();
}

function messageText(msg: any): string {
  const plain = findPart(msg.payload, 'text/plain');
  if (plain) return cleanBody(plain);
  const html = findPart(msg.payload, 'text/html');
  if (html) return cleanBody(htmlToText(html));
  return decodeEntities(String(msg.snippet ?? ''));
}

const cleanSubject = (subject: string): string => subject.replace(/^((re|fwd?|fw)\s*:\s*)+/i, '').trim();

/** The inbox as people, plus reading, replying and filing mail as tasks. */
export class Inbox {
  private cache: { at: number; people: InboxPerson[] } | null = null;

  constructor(
    private planner: Planner,
    private gmail: Gmail | undefined,
  ) {}

  private client(): Gmail {
    if (!this.gmail?.connected) throw new GmailNotConnected();
    return this.gmail;
  }

  clearCache(): void {
    this.cache = null;
  }

  private openTasksFor(email: string): Task[] {
    const e = email.toLowerCase();
    return this.planner.listTasks().filter((t) => t.status !== 'done' && t.contact?.email?.toLowerCase() === e);
  }

  /** The other person in a thread: the latest sender who isn't me, else who I wrote to. */
  private otherParty(messages: any[], me: string): Address | null {
    for (const msg of [...messages].reverse()) {
      const from = parseAddress(header(msg, 'From'));
      if (from.email && from.email !== me) return from;
    }
    const to = header(messages[messages.length - 1], 'To').split(',')[0];
    return to ? parseAddress(to) : null;
  }

  async people(): Promise<InboxPerson[]> {
    const gmail = this.client();
    if (this.cache && Date.now() - this.cache.at < CACHE_MS) return this.withTasks(this.cache.people);
    const me = await gmail.myEmail();
    const ids = await gmail.listThreadIds(PRIMARY, 50);
    const threads = await Promise.all(ids.map((id) => gmail.getThread(id, 'metadata')));

    const byEmail = new Map<string, InboxPerson>();
    for (const t of threads) {
      const messages: any[] = t.messages ?? [];
      if (!messages.length) continue;
      const who = this.otherParty(messages, me);
      if (!who) continue;
      const last = messages[messages.length - 1];
      const thread: InboxThread = {
        id: String(t.id),
        subject: header(messages[0], 'Subject'),
        snippet: decodeEntities(String(last.snippet ?? '')),
        lastAt: new Date(Number(last.internalDate ?? Date.now())).toISOString(),
        unread: messages.some((m) => (m.labelIds ?? []).includes('UNREAD')),
        messageCount: messages.length,
      };
      const person = byEmail.get(who.email) ?? { email: who.email, name: who.name, lastAt: thread.lastAt, unread: 0, threads: [], taskIds: [] };
      person.threads.push(thread);
      if (thread.unread) person.unread++;
      if (thread.lastAt > person.lastAt) person.lastAt = thread.lastAt;
      byEmail.set(who.email, person);
    }
    const people = [...byEmail.values()];
    for (const p of people) p.threads.sort((a, b) => b.lastAt.localeCompare(a.lastAt));
    this.cache = { at: Date.now(), people };
    return this.withTasks(people);
  }

  /** Fresh task links on every call, and people you're waiting on first. */
  private withTasks(people: InboxPerson[]): InboxPerson[] {
    const linked = people.map((p) => ({ ...p, taskIds: this.openTasksFor(p.email).map((t) => t.id) }));
    const waiting = (p: InboxPerson) => this.openTasksFor(p.email).some((t) => t.waitingOn);
    return linked.sort((a, b) => Number(waiting(b)) - Number(waiting(a)) || b.lastAt.localeCompare(a.lastAt));
  }

  async thread(id: string): Promise<InboxConversation> {
    const gmail = this.client();
    const me = await gmail.myEmail();
    const t = await gmail.getThread(id, 'full');
    const messages: InboxMessage[] = (t.messages ?? []).map((m: any) => {
      const from = parseAddress(header(m, 'From'));
      return {
        id: String(m.id),
        from,
        fromMe: from.email === me,
        at: new Date(Number(m.internalDate ?? Date.now())).toISOString(),
        text: messageText(m),
      };
    });
    return { id: String(t.id), subject: header(t.messages?.[0] ?? {}, 'Subject'), messages };
  }

  async reply(id: string, text: string): Promise<InboxConversation> {
    const gmail = this.client();
    if (!gmail.canReply) throw new Error('Reconnect Gmail to send replies.');
    const me = await gmail.myEmail();
    const t = await gmail.getThread(id, 'metadata');
    const messages: any[] = t.messages ?? [];
    if (!messages.length) throw new Error('That email thread is empty.');
    const last = messages[messages.length - 1];
    const to = this.otherParty(messages, me);
    if (!to) throw new Error('No one to reply to in that thread.');
    const subject = header(messages[0], 'Subject');
    const messageId = header(last, 'Message-ID');
    const references = [header(last, 'References'), messageId].filter(Boolean).join(' ');
    const raw = [
      `To: ${to.name ? `"${to.name.replace(/"/g, '')}" ` : ''}<${to.email}>`,
      `Subject: ${/^re:/i.test(subject) ? subject : `Re: ${subject}`}`,
      ...(messageId ? [`In-Reply-To: ${messageId}`, `References: ${references}`] : []),
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: 8bit',
      '',
      text,
    ].join('\r\n');
    await gmail.send(Buffer.from(raw, 'utf8').toString('base64url'), id);
    this.clearCache();

    // Writing to someone you're waiting on counts as chasing them: check again in two days.
    const zone = this.planner.getSettings().timezone || 'UTC';
    const followUpAt = DateTime.now().setZone(zone).plus({ days: 2 }).set({ hour: 9, minute: 0, second: 0, millisecond: 0 }).toUTC().toISO()!;
    for (const task of this.openTasksFor(to.email).filter((t) => t.waitingOn)) {
      await this.planner.updateTask(task.id, { status: 'waiting', followUpAt });
    }
    return this.thread(id);
  }

  async markRead(id: string): Promise<void> {
    const gmail = this.client();
    if (!gmail.canReply) return; // a read-only connection can't change labels; nothing to do
    await gmail.modifyThread(id, ['UNREAD']);
    this.clearCache();
  }

  async archive(id: string): Promise<void> {
    const gmail = this.client();
    if (!gmail.canReply) throw new Error('Reconnect Gmail to archive from here.');
    await gmail.modifyThread(id, ['INBOX']);
    this.clearCache();
  }

  async makeTask(id: string, kind: 'task' | 'followup'): Promise<Task> {
    const gmail = this.client();
    const me = await gmail.myEmail();
    const t = await gmail.getThread(id, 'metadata');
    const messages: any[] = t.messages ?? [];
    const who = this.otherParty(messages, me);
    const title = cleanSubject(header(messages[0] ?? {}, 'Subject')) || (who ? `Email from ${who.name}` : 'Email');
    const task = this.planner.createTask({
      title: title.slice(0, 300),
      source: 'gmail',
      externalRef: id,
      contact: who ? { name: who.name || who.email, email: who.email } : null,
      ...(kind === 'followup' && who ? { status: 'waiting' as const, waitingOn: who.name || who.email } : {}),
    });
    this.clearCache();
    return task;
  }
}
