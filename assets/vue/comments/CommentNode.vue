<script setup lang="ts">
import { ref, computed } from 'vue'
import { Button } from '@/assets/vue/components/ui/button'
import { MessageCircle, ChevronUp, Minus, Plus, CirclePlus, EyeOff } from '@lucide/vue'
import { useMarkdownPreview } from '@/assets/vue/composables/useMarkdownPreview'

defineOptions({ name: 'CommentNode' })

type CommentUser = { id: number; username: string } | null

export type CommentNodeData = {
  id: number
  bodyMarkdown: string | null
  bodyHtml: string
  voteScore: number
  upCount: number
  downCount: number
  insertedAt: string | null
  user: CommentUser
  parentId: number | null
  depth: number
  deleted: boolean
  hasMore: boolean
  replyCount: number
  children: CommentNodeData[]
}

const props = defineProps<{
  node: CommentNodeData
  currentUser: { id: number; username: string } | null
}>()

const emit = defineEmits<{
  (e: 'vote', payload: { id: number; vote: number }): void
  (e: 'reply', payload: { parentId: number; body: string }): void
  (e: 'loadMore', id: number): void
}>()

const collapsed = ref(false)
const showReply = ref(false)
const replyBody = ref('')
const replyTextareaRef = ref<HTMLTextAreaElement | null>(null)
const maxReplyLength = 10_000
const { previewHtml: previewHtmlReply } = useMarkdownPreview(() => replyBody.value)

function insertSpoilerReply() {
  const el = replyTextareaRef.value
  if (!el) { replyBody.value += '||spoiler||'; return }
  const start = el.selectionStart ?? replyBody.value.length
  const end = el.selectionEnd ?? replyBody.value.length
  const selected = replyBody.value.slice(start, end) || 'spoiler'
  const before = replyBody.value.slice(0, start)
  const after = replyBody.value.slice(end)
  replyBody.value = `${before}||${selected}||${after}`
  requestAnimationFrame(() => {
    el.focus()
    const pos = start + 2 + selected.length + 2
    el.setSelectionRange(pos, pos)
  })
}

const isDeleted = computed(() => props.node.deleted)
const depth = computed(() => props.node.depth)
const hasChildren = computed(() => props.node.children.length > 0)

function formatRelative(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  const diff = Date.now() - d.getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  if (days < 7) return `${days}d ago`
  return d.toLocaleDateString()
}

function handleVote(vote: number) {
  if (isDeleted.value) return
  emit('vote', { id: props.node.id, vote })
}

function toggleReply() {
  if (isDeleted.value) return
  if (!props.currentUser) {
    window.location.href = '/auth/login'
    return
  }
  showReply.value = !showReply.value
  if (showReply.value) replyBody.value = ''
}

function submitReply() {
  const body = replyBody.value.trim()
  if (!body) return
  if (!props.currentUser) {
    window.location.href = '/auth/login'
    return
  }
  emit('reply', { parentId: props.node.id, body })
  replyBody.value = ''
  showReply.value = false
}

function handleReplyKeydown(e: KeyboardEvent) {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') submitReply()
}

function toggleCollapse() {
  collapsed.value = !collapsed.value
}

const replyLength = computed(() => replyBody.value.length)

function getThreadLink(id: number) {
  const url = new URL(window.location.href)
  url.searchParams.set('thread', String(id))
  return url.toString()
}
</script>

<template>
  <div class="flex flex-col relative">
    <!-- Header: avatar + username / time / badge -->
    <div class="flex gap-1 items-center group/header">
      <div class="w-9 flex flex-col shrink-0 items-center">
        <div class="size-7 rounded-full bg-muted border flex items-center justify-center shrink-0">
          <span class="text-[10px] font-bold">{{ (node.user?.username || (isDeleted ? 'X' : 'A')).charAt(0).toUpperCase() }}</span>
        </div>
      </div>
      <div class="flex-1 min-w-0 flex items-center gap-2">
        <span class="text-xs font-semibold truncate" :class="isDeleted ? 'text-muted-foreground italic' : ''">
          {{ isDeleted ? '[deleted]' : (node.user?.username || 'Anonymous') }}
        </span>
        <span class="text-[10px] text-muted-foreground shrink-0">{{ formatRelative(node.insertedAt) }}</span>
        <!-- reply count + collapse (only when expanded) -->
        <span v-if="node.replyCount > 0 && !collapsed" class="ml-auto flex items-center gap-1">
          <span class="rounded-full bg-muted px-1.5 py-0.5 text-[10px] font-bold text-muted-foreground">
            {{ node.replyCount }} {{ node.replyCount === 1 ? 'reply' : 'replies' }}
          </span>
          <button
            type="button"
            class="size-6 rounded-md flex items-center justify-center hover:bg-accent border"
            aria-label="Collapse thread"
            @click="toggleCollapse"
          >
            <ChevronUp class="size-3 text-muted-foreground" />
          </button>
        </span>
        <!-- when collapsed, header shows no badge; banner below shows count -->
      </div>
    </div>

    <!-- Body + actions with left thread-line column (like Castra) -->
    <div class="flex gap-0.5">
      <!-- Left column: vertical line + interactive collapse circle (Crysa adoption, not 1:1 Castra) -->
      <div class="relative w-9 shrink-0">
        <div
          v-if="(hasChildren || node.replyCount > 0) && !collapsed"
          class="absolute top-0 bottom-0 left-4 w-px border-l border-muted group/line"
        />
        <!-- Crysa interactive thread-line: circle Minus/Plus on vertical (adopted, not Castra copy) -->
        <button
          v-if="hasChildren || node.replyCount > 0"
          type="button"
          class="absolute left-4 top-1 size-4 -translate-x-1/2 rounded-full border bg-card flex items-center justify-center shadow-sm hover:bg-accent transition-opacity"
          :class="collapsed ? 'opacity-100' : 'opacity-60 hover:opacity-100 group-hover/line:opacity-100'"
          :aria-label="collapsed ? 'Expand thread' : 'Collapse thread'"
          @click="toggleCollapse"
        >
          <Minus v-if="!collapsed" class="size-2.5 text-muted-foreground" />
          <Plus v-else class="size-2.5 text-muted-foreground" />
        </button>
      </div>

      <!-- Right column: body, votes, reply -->
      <div class="flex-1 min-w-0 flex flex-col gap-1.5 pb-1">
        <!-- Body -->
        <div
          v-if="!collapsed"
          class="prose prose-sm max-w-none text-xs leading-5 prose-p:my-1 prose-a:text-blue-600 dark:prose-a:text-blue-400 prose-a:underline prose-a:underline-offset-2 break-words"
          :class="isDeleted ? 'opacity-60' : ''"
          v-html="node.bodyHtml"
        />

        <!-- Collapsed placeholder (kept as requested) -->
        <div v-if="collapsed" class="text-[11px] text-muted-foreground italic">
          Thread collapsed — {{ node.replyCount }} {{ node.replyCount === 1 ? 'reply' : 'replies' }} hidden
          <button type="button" class="ml-1 font-bold text-primary hover:underline" @click="collapsed = false">Show</button>
        </div>

        <!-- Actions -->
        <div v-if="!collapsed && !isDeleted" class="flex items-center gap-1">
          <div class="flex items-center gap-0.5">
            <Button variant="ghost" size="xs" class="h-6 w-6 p-0 text-[11px] leading-none" aria-label="Upvote" @click="handleVote(1)">▲</Button>
            <span class="text-xs font-bold tabular-nums min-w-[14px] text-center">{{ node.upCount ?? 0 }}</span>
          </div>
          <div class="flex items-center gap-0.5">
            <Button variant="ghost" size="xs" class="h-6 w-6 p-0 text-[11px] leading-none" aria-label="Downvote" @click="handleVote(-1)">▼</Button>
            <span class="text-xs font-bold tabular-nums min-w-[14px] text-center">{{ node.downCount ?? 0 }}</span>
          </div>
          <Button variant="ghost" size="xs" class="h-6 px-2.5 text-[11px] ml-1" @click="toggleReply">Reply</Button>
        </div>

        <!-- Inline reply composer -->
        <div v-if="showReply && !collapsed && !isDeleted" class="mt-1 rounded-lg border bg-muted/30 p-2">
          <textarea
            v-model="replyBody"
            placeholder="Write a reply..."
            class="min-h-[56px] w-full resize-none rounded-md border bg-card p-2 text-xs placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
            :maxlength="maxReplyLength"
            @keydown="handleReplyKeydown"
          />
        <!-- Preview exactly below input -->
        <div v-if="previewHtmlReply" class="mt-2 rounded-lg border border-dashed bg-card p-2">
          <div class="text-[10px] font-bold tracking-wide text-muted-foreground uppercase mb-1">Preview</div>
          <div class="prose prose-sm max-w-none text-xs break-words prose-p:my-1 prose-a:text-blue-600 dark:prose-a:text-blue-400 prose-a:underline prose-a:underline-offset-2" v-html="previewHtmlReply" />
        </div>
        <div class="mt-2 flex items-center gap-1">
          <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent" title="Bold" @click="replyBody += '**bold**'">
            <span class="text-[11px] font-bold text-muted-foreground">B</span>
          </button>
          <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent" title="Italic" @click="replyBody += '*italic*'">
            <span class="text-[11px] italic text-muted-foreground">I</span>
          </button>
          <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent" title="Link" @click="replyBody += '[text](url)'">
            <span class="text-[10px] text-muted-foreground">🔗</span>
          </button>
          <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent" title="Spoiler" @click="insertSpoilerReply">
            <EyeOff class="size-3 text-muted-foreground" />
          </button>
        </div>
          <div class="mt-1.5 flex items-center justify-between">
            <span class="text-[10px] text-muted-foreground">{{ replyLength }}/{{ maxReplyLength }}</span>
            <div class="flex items-center gap-1.5">
              <Button variant="ghost" size="xs" class="h-6 text-[11px]" @click="showReply = false">Cancel</Button>
              <Button size="xs" class="h-6 text-[11px]" :disabled="!replyBody.trim()" @click="submitReply">Reply</Button>
            </div>
          </div>
        </div>

        <!-- HasMore (depth limit) -->
        <div v-if="!collapsed && node.hasMore" class="mt-1 rounded-md bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800 px-2 py-1.5 flex items-center justify-between">
          <span class="text-[11px] font-medium text-amber-800 dark:text-amber-200 flex items-center gap-1">
            <MessageCircle class="size-3" /> {{ node.replyCount }} hidden — continue
          </span>
          <Button variant="outline" size="xs" class="h-6 text-[11px] border-amber-200" @click="emit('loadMore', node.id)">Continue this thread →</Button>
        </div>
      </div>
    </div>

    <!-- Reply form when this node is parent and has existing replies: also show connector line above form (Castra) -->
    <div v-if="showReply && !collapsed && !isDeleted && hasChildren" class="flex gap-0 mt-2 relative">
      <div class="relative w-9 shrink-0">
        <div class="absolute -top-2 bottom-0 left-[17px] w-px border-l border-muted" />
      </div>
      <div class="flex-1 min-w-0" />
    </div>

    <!-- Children -->
    <div v-if="(hasChildren || node.replyCount>0) && !collapsed" class="flex flex-col">
      <!-- Depth limit: show More replies link like Castra -->
      <template v-if="depth >= 3 && hasChildren">
        <div class="flex gap-0 relative">
          <div class="relative w-9 shrink-0">
            <div
              class="absolute -top-4 bottom-0 left-4 w-px h-full border-b border-l border-muted rounded-bl-2xl"
              style="height: 30px; width: 18px"
            />
          </div>
          <div class="flex-1 min-w-0 flex h-[30px] text-center items-center">
            <a :href="getThreadLink(node.id)" class="text-foreground font-bold text-xs hover:underline flex items-center gap-1" data-sveltekit-noscroll>
              <CirclePlus class="size-4" />
              <span>{{ node.replyCount }} More {{ node.replyCount === 1 ? 'reply' : 'replies' }}</span>
            </a>
          </div>
        </div>
      </template>
      <template v-else>
        <div v-for="(child, i) in node.children" :key="child.id" class="flex gap-0 mt-2 relative">
          <div class="relative w-9 shrink-0">
            <!-- vertical continuation for siblings except last -->
            <div v-if="i !== node.children.length - 1" class="absolute -top-2 bottom-0 left-4 w-px border-l border-muted" />
            <!-- L shape: horizontal + vertical top to avatar -->
            <div
              class="absolute -top-2 bottom-0 left-4 w-px h-full border-b border-l border-muted rounded-bl-2xl"
              style="height: 30px; width: 18px"
            />
          </div>
          <div class="flex-1 min-w-0">
            <CommentNode :node="child" :current-user="currentUser" @vote="emit('vote', $event)" @reply="emit('reply', $event)" @loadMore="emit('loadMore', $event)" />
          </div>
        </div>
      </template>
    </div>
  </div>
</template>
