<script setup lang="ts">
import { ref, watch, computed, onMounted } from 'vue'
import { useLiveUpload } from 'live_vue'
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogClose,
} from 'reka-ui'
import { X, Plus, Upload } from '@lucide/vue'
import { Input } from '@/assets/vue/components/ui/input'
import { Button } from '@/assets/vue/components/ui/button'

type Tag = { id: number; name: string }

const props = defineProps<{
  open: boolean
  tags: Tag[]
  coverUpload?: any
}>()

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void
  (e: 'createSeries', data: {
    title: string
    originalTitle: string
    authorInput: string
    authors: string[]
    description: string
    sourceUrl: string
    selectedTagIds: number[]
    coverFileName: string | null
  }): void
}>()

const title = ref('')
const originalTitle = ref('')
const authorInput = ref('')
const authors = ref<string[]>([])
const description = ref('')
const sourceUrl = ref('')
const selectedTagIds = ref<Set<number>>(new Set())
const coverFileName = ref<string | null>(null)
const coverFile = ref<File | null>(null)
const coverPreviewUrl = ref<string | null>(null)
const coverInputKey = ref(0)

// LiveView upload — file is buffered in LiveView temp (RAM/disk) via allow_upload, then moved to Object Storage on create
const { entries: coverEntries, showFilePicker, addFiles, progress: coverProgress } = useLiveUpload(
  () => props.coverUpload,
  { changeEvent: undefined, submitEvent: undefined } as any,
)

watch(() => props.open, open => {
  if (open) {
    // reset form on open
    title.value = ''
    originalTitle.value = ''
    authorInput.value = ''
    authors.value = []
    description.value = ''
    sourceUrl.value = ''
    selectedTagIds.value = new Set()
    coverFileName.value = null
    coverFile.value = null
    if (coverPreviewUrl.value) {
      URL.revokeObjectURL(coverPreviewUrl.value)
      coverPreviewUrl.value = null
    }
    coverInputKey.value++
  }
})

// Auto-preview when LiveView reports an uploaded entry (after auto_upload)
watch(
  () => coverEntries.value?.[0]?.client_name,
  name => {
    if (name) coverFileName.value = name
  },
)

const isValid = computed(() => {
  return title.value.trim().length > 0 &&
    description.value.trim().length > 0 &&
    sourceUrl.value.trim().length > 0
})

function addAuthor() {
  const name = authorInput.value.trim()
  if (!name) return
  // normalize: capitalize each word, avoid duplicates
  const normalized = name.split(/\s+/).map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(' ')
  if (!authors.value.includes(normalized)) {
    authors.value.push(normalized)
  }
  authorInput.value = ''
}

function removeAuthor(name: string) {
  authors.value = authors.value.filter(a => a !== name)
}

function toggleTag(id: number) {
  const next = new Set(selectedTagIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  selectedTagIds.value = next
}

function onAuthorKeydown(e: KeyboardEvent) {
  if (e.key === 'Enter') {
    e.preventDefault()
    addAuthor()
  }
}

function onCoverChange(e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0] || null
  if (!file) return
  // Client preview immediately (before server upload completes)
  if (coverPreviewUrl.value) URL.revokeObjectURL(coverPreviewUrl.value)
  coverPreviewUrl.value = URL.createObjectURL(file)
  coverFile.value = file
  coverFileName.value = file.name
  // Push to LiveView temp (buffered in RAM/disk) — auto_upload will handle it,
  // but we also explicitly add via useLiveUpload for drag-drop compatibility
  try {
    addFiles([file])
  } catch (_) {
    // fallback: LiveView's hidden input will still capture via native change
  }
}

function onCoverBoxClick() {
  // Always use the native input we control — it gives us File for immediate preview
  // and we forward the File to LiveView temp via addFiles() (buffered in RAM/disk)
  const el = document.querySelector<HTMLInputElement>(`input[data-cover-native="${coverInputKey.value}"]`)
  if (el) el.click()
  else {
    // fallback to LiveView's hidden input if native not found
    try { showFilePicker() } catch (_) {}
  }
}

function handleCreate() {
  if (!isValid.value) return
  emit('createSeries', {
    title: title.value.trim(),
    originalTitle: originalTitle.value.trim(),
    authorInput: authorInput.value.trim(),
    authors: [...authors.value],
    description: description.value.trim(),
    sourceUrl: sourceUrl.value.trim(),
    selectedTagIds: [...selectedTagIds.value],
    coverFileName: coverFileName.value,
  })
}
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-50 bg-black/40 backdrop-blur-[1px]" />
      <DialogContent
        class="fixed left-1/2 top-1/2 z-50 w-full max-w-3xl max-h-[90vh] -translate-x-1/2 -translate-y-1/2 overflow-hidden rounded-xl border bg-card shadow-xl focus:outline-none flex flex-col"
      >
        <!-- Header -->
        <div class="flex items-center justify-between px-6 py-4 border-b">
          <DialogTitle class="text-base font-semibold">Add New Series</DialogTitle>
          <DialogClose class="rounded-md p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground" @click="emit('update:open', false)">
            <X class="size-4" />
          </DialogClose>
        </div>

        <!-- Body: two columns -->
        <div class="flex-1 overflow-auto">
          <div class="grid grid-cols-1 lg:grid-cols-5 gap-6 p-6">
            <!-- Left form (3 cols) -->
            <div class="lg:col-span-3 space-y-4">
              <div class="space-y-1.5">
                <label class="text-sm font-medium">Series Title <span class="text-destructive">*</span></label>
                <Input v-model="title" placeholder="" class="h-9" />
              </div>

              <div class="space-y-1.5">
                <label class="text-sm font-medium">Original Title</label>
                <Input v-model="originalTitle" placeholder="Optional" class="h-9 placeholder:text-muted-foreground/60" />
              </div>

              <div class="space-y-1.5">
                <label class="text-sm font-medium">Author</label>
                <div class="flex gap-2">
                  <Input v-model="authorInput" placeholder="" class="flex-1 h-9" @keydown="onAuthorKeydown" />
                  <Button size="icon" class="h-9 w-9 shrink-0" @click="addAuthor" :disabled="!authorInput.trim()">
                    <Plus class="size-4" />
                  </Button>
                </div>
                <div v-if="authors.length" class="flex flex-wrap gap-1.5">
                  <span v-for="a in authors" :key="a" class="inline-flex items-center gap-1 rounded-full bg-muted px-2.5 py-1 text-xs">
                    {{ a }}
                    <button type="button" class="rounded-full p-0.5 hover:bg-foreground/10" @click="removeAuthor(a)"><X class="size-3" /></button>
                  </span>
                </div>
              </div>

              <div class="space-y-1.5">
                <label class="text-sm font-medium">Description <span class="text-destructive">*</span></label>
                <textarea
                  v-model="description"
                  placeholder="Series Description"
                  rows="4"
                  class="flex min-h-[90px] w-full rounded-md border border-input bg-transparent px-3 py-2 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                />
              </div>

              <div class="space-y-1.5">
                <label class="text-sm font-medium">Source Url <span class="text-destructive">*</span></label>
                <Input v-model="sourceUrl" placeholder="" class="h-9" />
              </div>

              <div class="space-y-1.5">
                <label class="text-sm font-medium">Tags</label>
                <div class="flex flex-wrap gap-1.5 min-h-[28px] rounded-md border bg-muted/20 p-2">
                  <span v-if="selectedTagIds.size===0" class="text-xs text-muted-foreground py-0.5">No tags selected</span>
                  <span
                    v-for="id in [...selectedTagIds]"
                    :key="id"
                    class="inline-flex items-center gap-1 rounded-full bg-primary text-primary-foreground px-2.5 py-0.5 text-xs"
                  >
                    {{ tags.find(t=>t.id===id)?.name || id }}
                    <button type="button" class="rounded-full p-0.5 hover:bg-white/20" @click="toggleTag(id)"><X class="size-3" /></button>
                  </span>
                </div>
                <div class="flex flex-wrap gap-1.5">
                  <button
                    v-for="tag in tags"
                    :key="tag.id"
                    type="button"
                    class="rounded-full px-2.5 py-1 text-xs border transition-colors"
                    :class="selectedTagIds.has(tag.id) ? 'bg-primary text-primary-foreground border-primary' : 'bg-muted hover:bg-muted/80 border-transparent'"
                    @click="toggleTag(tag.id)"
                  >
                    {{ tag.name }}
                  </button>
                </div>
              </div>
            </div>

            <!-- Right cover (2 cols) — buffered in LiveView temp then moved to S3/R2 on Create -->
            <div class="lg:col-span-2 space-y-1.5">
              <label class="text-sm font-medium">Cover Image <span class="text-destructive">*</span></label>
              <div
                class="relative flex h-[280px] lg:h-[360px] w-full cursor-pointer flex-col items-center justify-center overflow-hidden rounded-lg border border-dashed bg-muted/20 p-4 text-center hover:bg-muted/30 transition-colors"
                @click="onCoverBoxClick"
              >
                <!-- Hidden native fallback input (LiveView also injects its own hidden input via useLiveUpload) -->
                <input
                  :key="coverInputKey"
                  :data-cover-native="coverInputKey"
                  type="file"
                  accept="image/jpeg,image/png,image/webp,image/gif"
                  class="hidden"
                  @change="onCoverChange"
                />
                <template v-if="coverPreviewUrl">
                  <img :src="coverPreviewUrl" alt="Cover preview" class="absolute inset-0 h-full w-full object-cover" />
                  <div class="absolute inset-0 bg-black/30 opacity-0 hover:opacity-100 transition-opacity flex items-center justify-center">
                    <span class="text-xs bg-card px-2 py-1 rounded shadow">Click to change</span>
                  </div>
                  <div v-if="coverEntries[0]?.progress != null && coverEntries[0].progress < 100" class="absolute bottom-0 left-0 h-1 w-full bg-muted">
                    <div class="h-full bg-primary transition-all" :style="{ width: (coverEntries[0].progress || 0) + '%' }" />
                  </div>
                </template>
                <template v-else-if="coverFileName">
                  <span class="text-sm font-medium truncate max-w-[180px]">{{ coverFileName }}</span>
                  <span class="text-xs text-muted-foreground mt-1">Click to change</span>
                  <span v-if="coverEntries[0]" class="text-xs text-muted-foreground">{{ coverEntries[0].progress }}% uploaded — buffered in RAM/disk</span>
                </template>
                <template v-else>
                  <Upload class="size-6 text-muted-foreground mb-2" />
                  <span class="text-sm text-muted-foreground">Choose file</span>
                </template>
              </div>
              <p class="text-xs text-muted-foreground">PNG, JPG, WebP up to 5MB — buffered in temp then stored to {{ coverEntries[0]?.progress != null ? coverEntries[0].progress + '% • ' : '' }}S3/R2 on Create</p>
            </div>
          </div>
        </div>

        <!-- Footer -->
        <div class="flex justify-end gap-2 px-6 py-4 border-t bg-muted/10">
          <Button variant="outline" class="h-8" @click="emit('update:open', false)">Cancel</Button>
          <Button class="h-8" :disabled="!isValid" @click="handleCreate">Create Series</Button>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
