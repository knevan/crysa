<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import { Check, ChevronUp, RotateCcw, X } from '@lucide/vue'
import type { BrowseCategory, TagState } from '@/assets/vue/catalog/browseTypes'

const props = defineProps<{
  categories: BrowseCategory[]
  includeTags: string[]
  excludeTags: string[]
}>()

const emit = defineEmits<{
  toggle: [name: string]
  reset: []
  apply: []
}>()

// Collapse is pure client chrome: never sent to the server.
const collapsed = shallowRef(false)

function tagState(name: string): TagState {
  if (props.includeTags.includes(name)) return 'include'
  if (props.excludeTags.includes(name)) return 'exclude'
  return 'none'
}

const includeCount = computed(() => props.includeTags.length)
const excludeCount = computed(() => props.excludeTags.length)
const hasActive = computed(() => includeCount.value > 0 || excludeCount.value > 0)
</script>

<template>
  <section class="w-full rounded-xl border border-[#E2E8F0] bg-white p-5" aria-label="Genre filter">
    <div class="flex w-full items-center justify-between">
      <h2 class="text-lg font-bold text-[#0F172A]">Filter Genres</h2>
      <button
        type="button"
        :aria-expanded="!collapsed"
        aria-controls="browse-filter-body"
        aria-label="Toggle genre filter"
        class="flex size-8 items-center justify-center rounded-full text-[#64748B] transition-colors hover:bg-[#F1F5F9]"
        @click="collapsed = !collapsed"
      >
        <ChevronUp class="size-4.5 transition-transform" :class="collapsed ? 'rotate-180' : ''" />
      </button>
    </div>

    <div v-show="!collapsed" id="browse-filter-body" class="mt-3.5 flex flex-col gap-3.5">
      <div class="h-px w-full bg-[#E2E8F0]" />

      <p v-if="categories.length === 0" class="text-sm text-[#64748B]">No tags yet.</p>

      <div v-else class="grid w-full grid-cols-2 gap-x-4 gap-y-4.5 md:grid-cols-3" role="group" aria-label="Genres">
        <button
          v-for="cat in categories"
          :key="cat.id"
          type="button"
          :aria-pressed="tagState(cat.name) !== 'none'"
          :data-state="tagState(cat.name)"
          class="flex w-full cursor-pointer items-center gap-2 px-1 py-1 text-left text-sm transition"
          @click="emit('toggle', cat.name)"
        >
          <span v-if="tagState(cat.name) === 'none'" class="w-4 shrink-0 text-center text-sm font-bold text-[#94A3B8]">?</span>
          <Check v-else-if="tagState(cat.name) === 'include'" class="size-4 w-4 shrink-0 text-[#16A34A]" />
          <X v-else class="size-4 w-4 shrink-0 text-[#DC2626]" />
          <span
            class="truncate"
            :class="
              tagState(cat.name) === 'include'
                ? 'font-medium text-[#16A34A]'
                : tagState(cat.name) === 'exclude'
                  ? 'font-medium text-[#DC2626]'
                  : 'text-[#0F172A]'
            "
          >
            {{ cat.name }}
          </span>
        </button>
      </div>

      <div class="h-px w-full bg-[#E2E8F0]" />

      <div class="flex w-full items-center justify-end gap-3">
        <button
          type="button"
          class="flex items-center gap-2 rounded-lg bg-[#F1F5F9] px-4.5 py-2.25 text-sm font-semibold text-[#0F172A] transition-colors hover:bg-[#E2E8F0]"
          @click="emit('reset')"
        >
          <RotateCcw class="size-3.75" />
          Reset
        </button>
        <button
          type="button"
          class="rounded-lg bg-[#0F172A] px-6.5 py-2.25 text-sm font-semibold text-white transition-colors hover:bg-[#1E293B]"
          @click="emit('apply')"
        >
          Search
        </button>
      </div>

      <div
        v-if="hasActive"
        class="flex w-full flex-wrap items-center gap-x-1.5 gap-y-1 rounded-lg border border-[#BFDBFE] bg-[#EFF6FF] px-4 py-3 text-[13px]"
        aria-live="polite"
      >
        <span class="font-bold text-[#0F172A]">Active Filters:</span>
        <span class="font-semibold text-[#16A34A]">Include:</span>
        <span class="text-[#64748B]">{{ includeCount }} tags</span>
        <span class="font-semibold text-[#DC2626]">Exclude:</span>
        <span class="text-[#64748B]">{{ excludeCount }} tags</span>
      </div>
    </div>
  </section>
</template>
