export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export async function api<T = any>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`/api${path}`, {
      method,
      headers: body ? { 'content-type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError('Could not reach Planner. Check your connection and try again.', 0);
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(data.error ?? `Request failed (${res.status}).`, res.status);
  return data as T;
}

export const DAY_MS = 86400_000;

export function startOfDay(d: Date): Date {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

export function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

export function startOfWeek(d: Date): Date {
  const x = startOfDay(d);
  return addDays(x, -((x.getDay() + 6) % 7)); // Monday
}

export const sameDay = (a: Date, b: Date) => startOfDay(a).getTime() === startOfDay(b).getTime();

const timeFmt = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const dayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
const weekdayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short' });
const monthFmt = new Intl.DateTimeFormat(undefined, { month: 'long', year: 'numeric' });

export const fmtTime = (d: Date | string) => timeFmt.format(new Date(d)).replace(':00', '');
export const fmtDay = (d: Date | string) => dayFmt.format(new Date(d));
export const fmtWeekday = (d: Date | string) => weekdayFmt.format(new Date(d));
export const fmtMonth = (d: Date | string) => monthFmt.format(new Date(d));

/** "today 2 PM", "tomorrow", "Fri, Nov 27 9:30 AM" */
export function fmtWhen(iso: string, withTime = true): string {
  const d = new Date(iso);
  const diff = Math.round((startOfDay(d).getTime() - startOfDay(new Date()).getTime()) / DAY_MS);
  const day = diff === 0 ? 'today' : diff === 1 ? 'tomorrow' : diff === -1 ? 'yesterday' : fmtDay(d);
  // A due time of 23:59 means "that day", so the clock time is noise.
  const endOfDay = d.getHours() === 23 && d.getMinutes() === 59;
  return withTime && !endOfDay ? `${day} ${fmtTime(d)}` : day;
}

export function fmtDuration(min: number): string {
  if (min < 60) return `${min} min`;
  const h = Math.floor(min / 60);
  const m = min % 60;
  return m ? `${h} h ${m} min` : `${h} h`;
}

/** Value for <input type="datetime-local"> in the browser's timezone. */
export function toLocalInput(iso: string | Date): string {
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

export const fromLocalInput = (v: string) => new Date(v).toISOString();
