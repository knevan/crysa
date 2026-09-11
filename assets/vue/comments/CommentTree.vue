<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import { Button } from '@/assets/vue/components/ui/button'
import { MessageCircle, Bold, Italic, Link2, Smile, Send, EyeOff, MoveRight } from '@lucide/vue'
import CommentNode, { type CommentNodeData } from './CommentNode.vue'
import { useMarkdownPreview } from '@/assets/vue/composables/useMarkdownPreview'

type Pagination = {
  page: number
  pageSize: number
  totalEntries: number
  totalPages: number
  hasPrevious: boolean
  hasNext: boolean
}

const props = defineProps<{
  tree: CommentNodeData[]
  pagination: Pagination
  sort: string
  count: number
  currentUser: { id: number; username: string } | null
  threadId: number | null
  isThreadView: boolean
}>()

const live = useLiveVue()

// --- Top-level composer for new root comment ---
const commentBody = ref('')
const commentTextareaRef = ref<HTMLTextAreaElement | null>(null)
const maxCommentLength = 10_000
const commentLength = computed(() => commentBody.value.length)
const { previewHtml: previewHtmlRoot } = useMarkdownPreview(() => commentBody.value)

function insertSpoiler() {
  const el = commentTextareaRef.value
  if (!el) { commentBody.value += '||spoiler||'; return }
  const start = el.selectionStart ?? commentBody.value.length
  const end = el.selectionEnd ?? commentBody.value.length
  const selected = commentBody.value.slice(start, end) || 'spoiler'
  const before = commentBody.value.slice(0, start)
  const after = commentBody.value.slice(end)
  commentBody.value = `${before}||${selected}||${after}`
  requestAnimationFrame(() => {
    el.focus()
    const pos = start + 2 + selected.length + 2
    el.setSelectionRange(pos, pos)
  })
}

const commentSort = ref(props.sort || 'newest')
watch(() => props.sort, v => (commentSort.value = v))

const treeNodes = computed(() => props.tree ?? [])
const isGuest = computed(() => !props.currentUser)

function goLogin() {
  window.location.href = '/auth/login'
}

function submitRootComment() {
  if (!props.currentUser) {
    window.location.href = '/auth/login'
    return
  }
  const body = commentBody.value.trim()
  if (!body) return
  live.pushEvent('create_comment', { body })
  commentBody.value = ''
}

function handleCommentKeydown(e: KeyboardEvent) {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    submitRootComment()
  }
}

function voteComment(payload: { id: number; vote: number }) {
  if (!props.currentUser) {
    window.location.href = '/auth/login'
    return
  }
  live.pushEvent('vote_comment', { id: payload.id, vote: payload.vote })
}

function replyToComment(payload: { parentId: number; body: string }) {
  if (!props.currentUser) {
    window.location.href = '/auth/login'
    return
  }
  const body = payload.body.trim()
  if (!body) return
  live.pushEvent('create_comment', { body, parent_id: payload.parentId })
}

function loadMoreThread(id: number) {
  // "Continue this thread" → parent before More replies becomes new head
  live.pushEvent('load_more_replies', { id })
}

function clearThread() {
  live.pushEvent('clear_thread', {})
}

function setCommentSort(sort: string) {
  commentSort.value = sort
  live.pushEvent('sort_comments', { sort })
}

function goCommentPage(page: number) {
  live.pushEvent('comment_page_change', { page })
}
</script>

<template>
  <div class="flex flex-col">
    <!-- Composer -->
    <div class="p-3">
      <div class="rounded-xl border bg-card overflow-hidden">
        <div class="bg-muted/30 p-2.5">
          <!-- Guest locked box: text + button stacked, both centered in box -->
          <div
            v-if="isGuest"
            class="flex min-h-18 w-full cursor-pointer flex-col items-center justify-center gap-3 rounded-lg border bg-card p-2.5"
            @click="goLogin"
          >
            <span class="text-xs text-muted-foreground">Share your thoughts...</span>
            <button
              type="button"
              aria-label="Login to comment"
              class="flex size-8 items-center justify-center rounded-lg border border-primary bg-card text-primary shadow-sm hover:bg-accent"
              @click.stop="goLogin"
            >
              <MoveRight class="size-4" />
            </button>
          </div>
          <textarea
            v-else
            ref="commentTextareaRef"
            v-model="commentBody"
            placeholder="Share your thoughts..."
            class="min-h-18 w-full resize-none rounded-lg border bg-card p-2.5 text-xs placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
            :maxlength="maxCommentLength"
            @keydown="handleCommentKeydown"
          />
          <!-- Preview exactly below input (dashed, like image) -->
          <div v-if="previewHtmlRoot" class="mt-2 rounded-lg border border-dashed bg-card p-2.5">
            <div class="text-[10px] font-bold tracking-wide text-muted-foreground uppercase mb-1">Preview</div>
            <div class="prose prose-sm max-w-none text-xs wrap-break-word prose-p:my-1 prose-a:text-blue-600 dark:prose-a:text-blue-400 prose-a:underline prose-a:underline-offset-2" v-html="previewHtmlRoot" />
          </div>
          <div class="mt-2 flex items-center justify-between">
            <div class="flex items-center gap-1">
              <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent disabled:opacity-40 disabled:pointer-events-none" title="Bold" :disabled="isGuest" @click="commentBody += '**bold**'">
                <Bold class="size-3 text-muted-foreground" />
              </button>
              <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent disabled:opacity-40 disabled:pointer-events-none" title="Italic" :disabled="isGuest" @click="commentBody += '*italic*'">
                <Italic class="size-3 text-muted-foreground" />
              </button>
              <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent disabled:opacity-40 disabled:pointer-events-none" title="Link" :disabled="isGuest" @click="commentBody += '[text](url)'">
                <Link2 class="size-3 text-muted-foreground" />
              </button>
              <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent disabled:opacity-40 disabled:pointer-events-none" title="Spoiler" :disabled="isGuest" @click="insertSpoiler">
                <EyeOff class="size-3 text-muted-foreground" />
              </button>
              <button type="button" class="size-6 rounded-md flex items-center justify-center hover:bg-accent disabled:opacity-40 disabled:pointer-events-none" title="Emoji" :disabled="isGuest">
                <Smile class="size-3 text-muted-foreground" />
              </button>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-[10px] text-muted-foreground">{{ commentLength }}/{{ maxCommentLength }}</span>
              <Button
                size="sm"
                class="h-7 rounded-lg px-3 text-xs gap-1"
                :disabled="!isGuest && (!commentBody.trim() || commentLength > maxCommentLength)"
                @click="submitRootComment"
              >
                Send
                <Send class="size-3" />
              </Button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- See full comments: align right, no border, blend with comment section bg, blue text -->
    <div v-if="isThreadView" class="px-3.5 py-2 flex justify-end bg-card">
      <button type="button" class="text-xs font-medium text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300 hover:underline" @click="clearThread">
        ← See full comments
      </button>
    </div>

    <!-- Sort (hidden in thread view — thread is chronological) -->
    <div v-if="!isThreadView" class="flex items-center gap-3 px-3.5 py-2 border-y bg-muted/20">
      <button
        type="button"
        class="relative pb-1 text-xs font-bold"
        :class="commentSort === 'newest' ? 'text-primary' : 'text-muted-foreground'"
        @click="setCommentSort('newest')"
      >
        Newest
        <span v-if="commentSort === 'newest'" class="absolute inset-x-0 -bottom-1.5 h-0.5 bg-primary rounded-full" />
      </button>
      <button
        type="button"
        class="relative pb-1 text-xs font-medium"
        :class="commentSort === 'oldest' ? 'text-primary font-bold' : 'text-muted-foreground'"
        @click="setCommentSort('oldest')"
      >
        Oldest
        <span v-if="commentSort === 'oldest'" class="absolute inset-x-0 -bottom-1.5 h-0.5 bg-primary rounded-full" />
      </button>
      <button
        type="button"
        class="relative pb-1 text-xs font-medium"
        :class="commentSort === 'most_voted' ? 'text-primary font-bold' : 'text-muted-foreground'"
        @click="setCommentSort('most_voted')"
      >
        Most Vote
        <span v-if="commentSort === 'most_voted'" class="absolute inset-x-0 -bottom-1.5 h-0.5 bg-primary rounded-full" />
      </button>
    </div>

    <!-- Empty -->
    <div v-if="treeNodes.length === 0" class="flex flex-col items-center gap-2 px-4 py-8">
      <div class="size-11 rounded-xl bg-muted flex items-center justify-center border">
        <MessageCircle class="size-5 text-muted-foreground" />
      </div>
      <p class="text-xs text-muted-foreground text-center max-w-65">No comments yet. Be the first to share your thoughts!</p>
      <p v-if="!currentUser" class="text-[11px] text-muted-foreground">
        Please <a href="/auth/login" class="font-bold text-primary">login</a> to join.
      </p>
    </div>

    <!-- Tree -->
    <div v-else class="divide-y">
      <div v-for="node in treeNodes" :key="node.id" class="px-3.5 pb-3.5 pt-1">
        <CommentNode
          :node="node"
          :current-user="currentUser"
          @vote="voteComment"
          @reply="replyToComment"
          @loadMore="loadMoreThread"
        />
      </div>
    </div>

    <!-- Pagination for roots (hidden in thread view) -->
    <div
      v-if="!isThreadView && pagination.totalPages > 1"
      class="flex items-center justify-between px-3.5 py-3 border-t bg-muted/20"
    >
      <Button
        variant="ghost"
        size="sm"
        :disabled="!pagination.hasPrevious"
        class="h-7 text-xs"
        @click="goCommentPage(pagination.page - 1)"
      >
        Previous
      </Button>
      <span class="text-xs text-muted-foreground">
        Page {{ pagination.page }} of {{ pagination.totalPages }}
      </span>
      <Button
        variant="ghost"
        size="sm"
        :disabled="!pagination.hasNext"
        class="h-7 text-xs"
        @click="goCommentPage(pagination.page + 1)"
      >
        Next
      </Button>
    </div>
  </div>
</template>
