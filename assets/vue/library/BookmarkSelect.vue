<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, useTemplateRef } from 'vue'
import { Check, ChevronDown } from '@lucide/vue'

export type SelectOption = { value: string; label: string }

const props = defineProps<{
  modelValue: string
  options: SelectOption[]
  // Named `label` (not `ariaLabel`)
  label: string
}>()

const emit = defineEmits<{
  'update:modelValue': [value: string]
}>()

const open = ref(false)
const root = useTemplateRef<HTMLDivElement>('root')

const currentLabel = computed(
  () => props.options.find((o) => o.value === props.modelValue)?.label ?? '',
)

function toggle() {
  open.value = !open.value
}

function choose(value: string) {
  open.value = false
  if (value !== props.modelValue) emit('update:modelValue', value)
}

// Each instance ignores clicks inside its own root (the trigger button
// toggles via its own handler) and closes on outside clicks, so opening
// one dropdown automatically closes any other open one.
function onDocumentClick(e: MouseEvent) {
  if (open.value && root.value && !root.value.contains(e.target as Node)) {
    open.value = false
  }
}

function onDocumentKey(e: KeyboardEvent) {
  if (e.key === 'Escape') open.value = false
}

onMounted(() => {
  document.addEventListener('click', onDocumentClick)
  document.addEventListener('keydown', onDocumentKey)
})

onBeforeUnmount(() => {
  document.removeEventListener('click', onDocumentClick)
  document.removeEventListener('keydown', onDocumentKey)
})
</script>

<template>
  <div ref="root" class="relative block w-full">
    <button
      type="button"
      :aria-label="label"
      aria-haspopup="listbox"
      :aria-expanded="open"
      class="flex w-full items-center justify-between gap-2 rounded-lg border border-[#93C5FD] dark:border-blue-800 bg-white dark:bg-card py-2.5 pl-4 pr-3 text-[13px] font-semibold text-[#0F172A] dark:text-zinc-100 outline-none transition-colors focus-visible:ring-1 focus-visible:ring-[#2563EB]"
      @click="toggle"
    >
      <span class="truncate">{{ currentLabel }}</span>
      <ChevronDown
        class="size-3.75 shrink-0 text-[#64748B] dark:text-zinc-400 transition-transform"
        :class="open ? 'rotate-180' : ''"
      />
    </button>

    <div
      v-if="open"
      role="listbox"
      :aria-label="label"
      class="absolute right-0 top-full z-30 mt-1 w-max min-w-full max-w-[calc(100vw-2rem)] overflow-hidden rounded-xl border border-[#93C5FD] dark:border-blue-800 bg-white dark:bg-card"
    >
      <button
        v-for="opt in options"
        :key="opt.value"
        type="button"
        role="option"
        :aria-selected="opt.value === modelValue"
        class="flex w-full items-center justify-between gap-2 px-4 py-2.5 text-left text-[13px] transition-colors hover:bg-[#F1F5F9] dark:hover:bg-muted"
        :class="opt.value === modelValue ? 'font-bold text-[#1D4ED8] dark:text-blue-400' : 'font-semibold text-[#0F172A] dark:text-zinc-100'"
        @click="choose(opt.value)"
      >
        <span class="truncate">{{ opt.label }}</span>
        <Check v-if="opt.value === modelValue" class="size-3.5 shrink-0" />
      </button>
    </div>
  </div>
</template>
