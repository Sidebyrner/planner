import type { ChecklistItem } from './types.js';

// "1. Balance the drawer", "2) Order mix", "- Primer", "* Tape", "[ ] Sand", "- [x] Done"
const ITEM = /^\s*(?:\d+[.)]|[-*•])?\s*(?:\[( |x|X)\])?\s*(.+?)\s*$/;
const MARKER = /^\s*(?:\d+[.)]|[-*•]|\[[ xX]\])\s+/;

/**
 * Split notes into checklist items and the prose that is left over.
 * Only lines that start with a list marker become items, so a paragraph of
 * notes stays notes.
 */
export function checklistFromNotes(notes: string, makeId: () => string): { items: ChecklistItem[]; rest: string } {
  const items: ChecklistItem[] = [];
  const rest: string[] = [];
  for (const line of notes.split(/\r?\n/)) {
    if (!MARKER.test(line)) {
      rest.push(line);
      continue;
    }
    const m = line.match(ITEM);
    const text = m?.[2]?.trim();
    if (!text) continue;
    items.push({ id: makeId(), text, done: m?.[1] === 'x' || m?.[1] === 'X' });
  }
  return { items, rest: rest.join('\n').trim() };
}
