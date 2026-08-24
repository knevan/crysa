import type { ClassValue } from "clsx"
import { clsx } from "clsx"
import { twMerge } from "tailwind-merge"

/**
 * Merges Tailwind classes with proper precedence.
 * Canonical implementation per plan.md § Asset Pipeline: Vite.
 * Used by all shadcn-vue primitives.
 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
