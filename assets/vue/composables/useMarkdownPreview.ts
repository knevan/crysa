import { ref, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import { useDebounceFn } from '@vueuse/core'

/**
 * Server-side markdown preview.
 * Debounced to avoid spamming the server; uses `preview_markdown` LiveView event.
 */
export function useMarkdownPreview(source: () => string) {
  const live = useLiveVue()
  const previewHtml = ref('')
  const isPreviewLoading = ref(false)

  const fetchPreview = useDebounceFn(async (markdown: string) => {
    const trimmed = markdown.trim()
    if (!trimmed) {
      previewHtml.value = ''
      isPreviewLoading.value = false
      return
    }

    isPreviewLoading.value = true
    try {
      // LiveView handle_event replies with %{html: ...}
      const result: { html?: unknown } = await live.pushEvent('preview_markdown', {
        markdown: trimmed.slice(0, 10_000),
      })

      // `pushEvent` with reply returns %{html: ...} directly or via promise
      const html = result?.html ?? result?.['html'] ?? ''
      previewHtml.value = typeof html === 'string' ? html : ''
    } catch {
      // Keep previous preview on error; do not clear
      isPreviewLoading.value = false
      return
    }
    isPreviewLoading.value = false
  }, 300)

  // Watch source and trigger debounced fetch
  // Use a dummy ref to watch the getter
  const trigger = ref(0)
  // We use watch with getter instead of watch(source) to support () => string
  watch(
    () => source(),
    (val) => {
      trigger.value++
      fetchPreview(val)
    },
  )

  // Also fetch immediately if source initially has content
  // (e.g., when replyBody is prefilled with "@user ")
  fetchPreview(source())

  return { previewHtml, isPreviewLoading }
}
