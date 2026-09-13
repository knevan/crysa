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
const autoplay = Autoplay({
  delay: 3000,
  stopOnInteraction: false,
  stopOnMouseEnter: false,
  stopOnFocusIn: false,
})

const [emblaRef, emblaApi] = useEmblaCarousel({ align: 'start', dragFree: true, loop: true }, [
  autoplay,
])

// Default to scrollable (loop mode) so SSR first paint shows the nav buttons; 
// syncNavButtons corrects this once Embla measures.
const canScrollPrev = shallowRef(true)
const canScrollNext = shallowRef(true)
// Pause sources tracked: touch/drag, mouse hover, keyboard focus
// Resume waits 3s idle after ALL sources clear. Hover uses
// mouse-typed pointer events only, so touch-emulated mouse events can never
// latch the hover state on mobile.
let resumeTimer: ReturnType<typeof setTimeout> | undefined
let isPointerDown = false
let isHovering = false
let domCleanup: (() => void) | undefined

function syncNavButtons(api: EmblaCarouselType) {
  canScrollPrev.value = api.canScrollPrev()
  canScrollNext.value = api.canScrollNext()
}

function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function clearResumeTimer() {
  if (resumeTimer !== undefined) {
    clearTimeout(resumeTimer)
    resumeTimer = undefined
  }
}

function pauseAutoplay() {
  clearResumeTimer()
  autoplay.stop()
}

function scheduleResume() {
  clearResumeTimer()
  // Hold the stopped state first: the plugin restarts its own timer on
  // pointerUp/visibility, so cancel that and resume only after 3s idle.
  autoplay.stop()
  if (prefersReducedMotion()) return
  resumeTimer = setTimeout(() => {
    resumeTimer = undefined
    if (typeof document !== 'undefined' && document.hidden) return
    if (isPointerDown || isHovering) return
    autoplay.play()
  }, 3000)
}

function onPointerDown() {
  isPointerDown = true
  pauseAutoplay()
}

function onPointerUp() {
  isPointerDown = false
  scheduleResume()
}

function onPointerEnter(event: PointerEvent) {
  if (event.pointerType !== 'mouse') return
  isHovering = true
  pauseAutoplay()
}

function onPointerLeave(event: PointerEvent) {
  if (event.pointerType !== 'mouse') return
  isHovering = false
  scheduleResume()
}

function onFocusIn() {
  pauseAutoplay()
}

function onFocusOut() {
  scheduleResume()
}

watch(
  emblaApi,
  (api) => {
    if (!api) return
    if (prefersReducedMotion()) autoplay.stop()
    api.on('pointerDown', onPointerDown)
    api.on('pointerUp', onPointerUp)
    api.on('select', syncNavButtons)
    api.on('reInit', syncNavButtons)
    syncNavButtons(api)

    // Viewport exists only client-side once Embla initialises; re-bind if
    // the api instance ever changes.
    domCleanup?.()
    const viewport = emblaRef.value
    if (viewport) {
      const controller = new AbortController()
      const opts: AddEventListenerOptions = { signal: controller.signal }
      viewport.addEventListener('pointerenter', onPointerEnter, opts)
      viewport.addEventListener('pointerleave', onPointerLeave, opts)
      viewport.addEventListener('focusin', onFocusIn, opts)
      viewport.addEventListener('focusout', onFocusOut, opts)
      domCleanup = () => controller.abort()
    }
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
  domCleanup?.()
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
      <!-- Slide spacing lives on the slide so the loop 
      wrap seam last->first keeps the same gutter. -->
      <div class="flex">
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
