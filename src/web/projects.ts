import type { CSSProperties } from 'react';
import type { Project } from '../shared/types';

export type ProjectMap = Map<string, Project>;

export function projectMap(projects: Project[]): ProjectMap {
  return new Map(projects.map((p) => [p.id, p]));
}

/** CSS custom properties that colour an element by its project (see --p-* in styles.css). */
export function projectStyle(p: Project | undefined | null): CSSProperties {
  if (!p) return {};
  return { ['--proj' as string]: `var(--p-${p.color})`, ['--proj-soft' as string]: `var(--p-${p.color}-soft)` };
}

export function projectLabel(p: Project): string {
  return p.emoji ? `${p.emoji} ${p.name}` : p.name;
}
