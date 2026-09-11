<script setup lang="ts">
import { nextTick, onUnmounted, shallowRef, watch } from 'vue'
import useEmblaCarousel from 'embla-carousel-vue'
import Autoplay from 'embla-carousel-autoplay'
import type { EmblaCarouselType } from 'embla-carousel'
import { ChevronLeft, ChevronRight } from '@lucide/vue'
import TrendingCard from '@/assets/vue/trending/TrendingCard.vue'
import type { TrendingItem } from '@/assets/vue/trending/types'

const props = defineProps<{
  items: TrendingItem[]
}>()

// Autoplay construction
const autoplay = Autoplay({ delay: 3000, stopOnInteraction: true, stopOnMouseEnter: true })

const [emblaRef, emblaApi] = useEmblaCarousel({ align: 'start', dragFree: true, loop: true }, [
  autoplay,
])

// Default to scrollable (loop mode) so SSR first paint shows the nav buttons; 
// syncNavButtons corrects this once Embla measures.
const canScrollPrev = shallowRef(true)
const canScrollNext = shallowRef(true)
// Idle timer that resumes autoplay 3s after the last interruption
// (drag, hover-leave gap, hidden tab shown again).
let resumeTimer: ReturnType<typeof setTimeout> | undefined

function syncNavButtons(api: EmblaCarouselType) {
  canScrollPrev.value = api.canScrollPrev()
  canScrollNext.value = api.canScrollNext()
}

function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function hasFineHover(): boolean {
  return typeof window !== 'undefined' && window.matchMedia('(hover: hover) and (pointer: fine)').matches
}

function clearResumeTimer() {
  if (resumeTimer !== undefined) {
    clearTimeout(resumeTimer)
    resumeTimer = undefined
  }
}

function scheduleResume() {
  clearResumeTimer()
  if (prefersReducedMotion()) return
  resumeTimer = setTimeout(() => {
    resumeTimer = undefined
    if (typeof document !== 'undefined' && document.hidden) return
    // Don't fight the plugin's own mouse-enter pause on desktop.
    if (hasFineHover() && emblaRef.value?.matches(':hover')) return
    autoplay.play()
  }, 3000)
}

watch(
  emblaApi,
  (api) => {
    if (!api) return
    if (prefersReducedMotion()) autoplay.stop()
    // The plugin stops itself on interaction; resume after 3s idle.
    api.on('pointerDown', clearResumeTimer)
    api.on('pointerUp', scheduleResume)
    api.on('select', syncNavButtons)
    api.on('reInit', syncNavButtons)
    syncNavButtons(api)
  },
  { immediate: true },
)

// Tab switches replace the list: re-measure the track and restart from the
// first snap. nextTick waits for Vue to flush the new slides into the DOM.
watch(
  () => props.items,
  async () => {
    const api = emblaApi.value
    if (!api) return
    await nextTick()
    api.reInit()
    api.scrollTo(0, true)
  },
)

function onVisibilityChange() {
  if (typeof document === 'undefined') return
  if (document.hidden) {
    clearResumeTimer()
    autoplay.stop()
  } else {
    // Consistent with post-interaction behavior: resume after 3s idle.
    scheduleResume()
  }
}

if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', onVisibilityChange)
}

onUnmounted(() => {
  clearResumeTimer()
  if (typeof document !== 'undefined') {
    document.removeEventListener('visibilitychange', onVisibilityChange)
  }
})
</script>

<template>
  <div v-if="props.items.length === 0" class="rounded-lg bg-base-200 p-10 text-center">
    <p class="text-sm text-base-content/60">No trending series yet.</p>
  </div>
  <div v-else class="trending-carousel relative">
    <div ref="emblaRef" class="overflow-hidden select-none">
      <div class="flex gap-3">
        <TrendingCard v-for="(item, index) in props.items" :key="item.id" :item="item" :rank="index + 1" />
      </div>
    </div>
    <button
      type="button"
      aria-label="Scroll trending backwards"
      :disabled="!canScrollPrev"
      class="btn btn-circle btn-sm absolute top-1/3 -left-2 hidden border border-gray-200 bg-white text-gray-900 shadow-md disabled:opacity-0 sm:inline-flex dark:border-neutral-700 dark:bg-neutral-800 dark:text-white"
      @click="emblaApi?.scrollPrev()"
    >
      <ChevronLeft class="h-4 w-4" />
    </button>
    <button
      type="button"
      aria-label="Scroll trending forwards"
      :disabled="!canScrollNext"
      class="btn btn-circle btn-sm absolute top-1/3 -right-2 hidden border border-gray-200 bg-white text-gray-900 shadow-md disabled:opacity-0 sm:inline-flex dark:border-neutral-700 dark:bg-neutral-800 dark:text-white"
      @click="emblaApi?.scrollNext()"
    >
      <ChevronRight class="h-4 w-4" />
    </button>
  </div>
</template>
