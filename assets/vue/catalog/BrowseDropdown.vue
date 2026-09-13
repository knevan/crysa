<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, shallowRef, useTemplateRef } from 'vue'
import { Check, ChevronDown } from '@lucide/vue'

export type DropdownOption = { value: string; label: string }

const props = withDefaults(
  defineProps<{
    options: DropdownOption[]
    value: string
    label: string
    variant?: 'neutral' | 'accent'
    fallbackLabel?: string
  }>(),
  { variant: 'neutral', fallbackLabel: '' },
)

const emit = defineEmits<{ pick: [value: string] }>()

// Pure client chrome; selection itself always comes from props (server truth).
const open = shallowRef(false)
const wrap = useTemplateRef<HTMLDivElement>('wrap')

const currentLabel = computed(
  () => props.options.find((o) => o.value === props.value)?.label ?? props.fallbackLabel,
)

function onDocClick(e: MouseEvent) {
  if (wrap.value && !wrap.value.contains(e.target as Node)) open.value = false
}

function onDocKey(e: KeyboardEvent) {
  if (e.key === 'Escape') open.value = false
}

onMounted(() => {
  document.addEventListener('click', onDocClick)
  document.addEventListener('keydown', onDocKey)
})

onBeforeUnmount(() => {
  document.removeEventListener('click', onDocClick)
  document.removeEventListener('keydown', onDocKey)
})

function pick(value: string) {
  open.value = false
  if (value !== props.value) emit('pick', value)
}
</script>

<template>
  <div ref="wrap" class="relative w-full sm:w-auto">
    <button
      type="button"
      aria-haspopup="listbox"
      :aria-expanded="open"
      :aria-label="props.label"
      class="flex h-10 w-full items-center justify-center gap-2.5 rounded-lg border bg-white dark:bg-card px-4 text-[13px] font-semibold text-[#0F172A] dark:text-zinc-100 transition-colors hover:bg-[#F8FAFC] dark:hover:bg-muted sm:w-auto"
      :class="props.variant === 'accent' ? 'border-[#93C5FD] dark:border-blue-800' : 'border-[#E2E8F0] dark:border-zinc-800'"
      @click="open = !open"
    >
      {{ currentLabel }}
      <ChevronDown
        class="size-3.75 shrink-0 text-[#64748B] dark:text-zinc-400 transition-transform"
        :class="open ? 'rotate-180' : ''"
      />
    </button>
    <ul
      v-if="open"
      role="listbox"
      :aria-label="props.label"
      class="absolute right-0 z-30 mt-1.5 w-full min-w-44 overflow-hidden rounded-lg border border-[#E2E8F0] dark:border-zinc-800 bg-white dark:bg-card py-1 shadow-xl sm:w-44"
    >
      <li v-for="o in props.options" :key="o.value" role="option" :aria-selected="o.value === props.value">
        <button
          type="button"
          class="flex w-full items-center justify-between px-3.5 py-2 text-left text-[13px] transition-colors hover:bg-[#F1F5F9] dark:hover:bg-muted"
          :class="o.value === props.value ? 'font-bold text-[#1D4ED8] dark:text-blue-400' : 'font-semibold text-[#0F172A] dark:text-zinc-100'"
          @click="pick(o.value)"
        >
          {{ o.label }}
          <Check v-if="o.value === props.value" class="size-3.5 shrink-0" />
        </button>
      </li>
    </ul>
  </div>
</template>
