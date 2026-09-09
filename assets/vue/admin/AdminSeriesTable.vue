<script setup lang="ts">
import { createColumnHelper, getCoreRowModel, useVueTable, FlexRender } from '@tanstack/vue-table'
import { computed, h, ref, watch } from 'vue'
import { Archive, ArchiveRestore, ClockFading, ListOrdered, Trash2 } from '@lucide/vue'

export type SeriesRow = {
  id: number
  title: string
  slug: string
  authors: string[]
  publicationStatus: string
  processingStatus: string
  sourceUrl: string | null
  coverUrl: string | null
  updatedAt: string | null
  insertedAt: string | null
  manualCheckIntervalMinutes: number | null
  effectiveIntervalMinutes: number | null
  nextCheckAt: string | null
  lastCheckedAt: string | null
  checkRetryCount: number
  lastError: string | null
  archivedAt: string | null
}

const props = defineProps<{
  data: SeriesRow[]
}>()

const emit = defineEmits<{
  (e: 'openChapters', row: SeriesRow): void
  (e: 'editSchedule', row: SeriesRow): void
  (e: 'deleteSeries', row: SeriesRow): void
  (e: 'archiveSeries', row: SeriesRow): void
  (e: 'unarchiveSeries', row: SeriesRow): void
}>()

const columnHelper = createColumnHelper<SeriesRow>()

function formatDate(iso: string | null): string {
  if (!iso) return '-'
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return '-'
    return d.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    })
  } catch {
    return '-'
  }
}

function hostFromUrl(url: string | null): string {
  if (!url) return '-'
  try {
    return new URL(url).host
  } catch {
    return url.length > 32 ? `${url.slice(0, 32)}…` : url
  }
}

function statusClass(status: string): string {
  switch (status) {
    case 'ongoing':
      return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-100'
    case 'completed':
      return 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-100'
    case 'hiatus':
      return 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-100'
    case 'discontinued':
      return 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

function processingStatusClass(status: string): string {
  switch (status) {
    case 'available':
      return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-100'
    case 'pending':
      return 'bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-100'
    case 'processing':
      return 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-100'
    case 'error':
      return 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
    case 'pending_deletion':
      return 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-100'
    case 'deleting':
      return 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-100'
    case 'deletion_failed':
      return 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

const dataRef = computed(() => [...props.data])

// Column sizing state — persisted client-side, enables drag-to-resize
const columnSizing = ref<Record<string, number>>({})

const columns = [
  columnHelper.accessor('id', {
    header: 'ID',
    cell: info => info.getValue(),
    size: 50,
    minSize: 50,
    maxSize: 100,
    enableResizing: true,
  }),
  columnHelper.accessor('title', {
    header: 'Series Name',
    cell: info => {
      const row = info.row.original
      return h('div', { class: 'font-medium truncate', title: row.title }, row.title)
    },
    size: 200,
    minSize: 200,
    enableResizing: true,
  }),
  columnHelper.accessor('authors', {
    header: 'Authors',
    cell: info => {
      const authors = info.getValue() as string[]
      if (!authors || authors.length === 0) return '-'
      const text = authors.join(', ')
      return h('div', { class: 'truncate', title: text }, text)
    },
    size: 140,
    minSize: 140,
    enableResizing: true,
  }),
  columnHelper.accessor('updatedAt', {
    header: 'Last Updated',
    cell: info => formatDate(info.getValue() as string | null),
    size: 100,
    minSize: 100,
    enableResizing: true,
  }),
  columnHelper.accessor('publicationStatus', {
    header: 'Public Status',
    cell: info => {
      const status = info.getValue() as string
      return h(
        'span',
        {
          class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium capitalize ${statusClass(status)}`,
        },
        status,
      )
    },
    size: 90,
    minSize: 90,
    enableResizing: true,
  }),
  columnHelper.accessor('processingStatus', {
    header: 'Process Status',
    cell: info => {
      const status = info.getValue() as string
      const label = status.replace('_', ' ')
      return h(
        'span',
        {
          class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium capitalize ${processingStatusClass(status)}`,
          title: status,
        },
        label,
      )
    },
    size: 110,
    minSize: 110,
    enableResizing: true,
  }),
  columnHelper.accessor('archivedAt', {
    header: 'Archived',
    cell: info => {
      const v = info.getValue() as string | null
      if (!v) return h('span', { class: 'text-xs text-muted-foreground' }, '—')
      const d = new Date(v)
      const label = Number.isNaN(d.getTime()) ? v.slice(0, 10) : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
      return h(
        'span',
        {
          class: 'inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium bg-zinc-800 text-white dark:bg-zinc-100 dark:text-zinc-900',
          title: v,
        },
        [h(Archive, { class: 'size-3' }), label],
      )
    },
    size: 110,
    minSize: 110,
    enableResizing: true,
  }),
  columnHelper.accessor('sourceUrl', {
    header: 'Source',
    cell: info => {
      const url = info.getValue() as string | null
      return h('span', { class: 'text-xs truncate block', title: url ?? '' }, hostFromUrl(url))
    },
    size: 150,
    minSize: 150,
    enableResizing: true,
  }),
  columnHelper.display({
    id: 'actions',
    header: 'Actions',
    cell: info => {
      const row = info.row.original
      const isArchived = !!row.archivedAt
      return h('div', { class: 'flex gap-1' }, [
        h(
          'button',
          {
            class:
              'inline-flex h-7 px-2 items-center justify-center rounded-md border border-input bg-background text-xs hover:bg-accent gap-1',
            title: `Chapters for ${row.title} — list/delete/repair (stable chapter_key, bounded pagination)`,
            onClick: () => emit('openChapters', row),
          },
          [h(ListOrdered, { class: 'size-3.5' })],
        ),
        h(
          'button',
          {
            class:
              'inline-flex h-7 w-7 items-center justify-center rounded-md border border-input bg-background text-xs hover:bg-accent',
            title: `Schedule for ${row.title} — effective ${row.effectiveIntervalMinutes ?? '—'}m, next ${row.nextCheckAt ?? '—'}`,
            onClick: () => emit('editSchedule', row),
          },
          [h(ClockFading, { class: 'size-3.5' })],
        ),
        h(
          'button',
          {
            class: isArchived
              ? 'inline-flex h-7 w-7 items-center justify-center rounded-md border border-input bg-amber-50 text-amber-700 border-amber-200 text-xs hover:bg-amber-100'
              : 'inline-flex h-7 w-7 items-center justify-center rounded-md border border-input bg-background text-xs hover:bg-accent',
            title: isArchived
              ? `Unarchive ${row.title} — will be visible again & rescheduled`
              : `Archive ${row.title} — delist from user UI instantly (keeps DB/storage, then delete one-by-one)`,
            onClick: () => (isArchived ? emit('unarchiveSeries', row) : emit('archiveSeries', row)),
          },
          [h(isArchived ? ArchiveRestore : Archive, { class: 'size-3.5' })],
        ),
        h(
          'button',
          {
            class:
              'inline-flex h-7 w-7 items-center justify-center rounded-md border border-input bg-background text-xs hover:bg-accent hover:text-destructive hover:border-destructive/50',
            title: `Delete ${row.title} — hard delete DB + cover + all chapter images from storage (via durable worker, one-by-one)` ,
            onClick: () => emit('deleteSeries', row),
          },
          [h(Trash2, { class: 'size-3.5' })],
        ),
      ])
    },
    size: 210,
    minSize: 210,
    enableResizing: true,
  }),
]

const table = useVueTable({
  data: dataRef,
  columns,
  state: {
    get columnSizing() {
      return columnSizing.value
    },
  },
  onColumnSizingChange: updater => {
    const next = typeof updater === 'function' ? updater(columnSizing.value) : updater
    columnSizing.value = next
  },
  columnResizeMode: 'onChange',
  enableColumnResizing: true,
  getCoreRowModel: getCoreRowModel(),
})

watch(
  () => props.data,
  (newData) => {
    table.setOptions((prev) => ({ ...prev, data: [...newData] }))
  },
  { deep: true },
)

watch(dataRef, (v) => {
  table.setOptions((prev) => ({ ...prev, data: [...v] }))
})

const headerGroups = computed(() => table.getHeaderGroups())
const rows = computed(() => {
  const _track = dataRef.value.length
  return table.getRowModel().rows
})
</script>

<template>
  <!-- Overflow container: when a column is resized beyond viewport, table overflows to the right and only that column grows -->
  <div class="w-full overflow-x-auto border-t">
    <table class="caption-bottom text-sm" :style="{ width: table.getTotalSize() + 'px', tableLayout: 'fixed' }">
      <thead class="[&_tr]:border-b bg-muted/50">
        <tr
          v-for="headerGroup in headerGroups"
          :key="headerGroup.id"
          class="border-b"
        >
          <th
            v-for="(header, idx) in headerGroup.headers"
            :key="header.id"
            class="relative h-9 px-3 text-left align-middle font-medium text-muted-foreground whitespace-nowrap select-none"
            :style="header.column.getSize() ? `width: ${header.column.getSize()}px` : undefined"
          >
            <FlexRender
              v-if="!header.isPlaceholder"
              :render="header.column.columnDef.header"
              :props="header.getContext()"
            />
            <!-- Separated line always visible (w-px bg-border). Resize handle is same thin line: only handle hover changes color -->
            <div
              v-if="header.column.getCanResize()"
              class="group/handle absolute right-0 top-0 flex h-full w-3 -mr-1.5 cursor-col-resize touch-none select-none justify-center"
              @mousedown="header.getResizeHandler()?.($event)"
              @touchstart="header.getResizeHandler()?.($event)"
            >
              <div
                class="h-full w-px bg-border transition-colors group-hover/handle:bg-foreground"
                :class="{ 'bg-foreground!': header.column.getIsResizing() }"
              />
            </div>
            <div v-else-if="idx < headerGroup.headers.length - 1 && !header.isPlaceholder" class="absolute right-0 top-0 h-full w-px bg-border" />
          </th>
        </tr>
      </thead>
      <tbody class="[&_tr:last-child]:border-0">
        <tr
          v-for="row in rows"
          :key="row.id"
          class="border-b transition-colors hover:bg-muted/50"
        >
          <td
            v-for="cell in row.getVisibleCells()"
            :key="cell.id"
            class="p-3 align-middle border-r border-border last:border-r-0"
          >
            <FlexRender :render="cell.column.columnDef.cell" :props="cell.getContext()" />
          </td>
        </tr>
        <tr v-if="rows.length === 0">
          <td :colspan="columns.length" class="h-24 text-center text-muted-foreground">
            No series found
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
