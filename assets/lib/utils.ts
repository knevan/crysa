// Re-export canonical implementation (Phase 1: Vite-only foundation)
// Kept for backward compatibility; new code should import from '@/assets/vue/lib/utils'
// Use relative path to avoid alias-resolution issues when this file
// is outside tsconfig "include" (editor TS server still checks open files).
export { cn } from "../vue/lib/utils"