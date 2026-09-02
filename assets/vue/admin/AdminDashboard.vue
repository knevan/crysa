<script setup lang="ts">
import { ref, watch, computed } from 'vue'
import { useDebounceFn } from '@vueuse/core'
import { useLiveVue } from 'live_vue'
import { Search, Tag, Plus } from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import AdminSeriesTable, { type SeriesRow } from '@/assets/vue/admin/AdminSeriesTable.vue'
import AdminUsersTable, { type UserRow } from '@/assets/vue/admin/AdminUsersTable.vue'
import AdminReportsTable, { type ReportRow } from '@/assets/vue/admin/AdminReportsTable.vue'
import AdminAuditTable, { type AuditRow } from '@/assets/vue/admin/AdminAuditTable.vue'
import ManageTagsDialog from '@/assets/vue/admin/ManageTagsDialog.vue'
import AddSeriesDialog from '@/assets/vue/admin/AddSeriesDialog.vue'
import ChapterListDialog, { type ChapterRow } from '@/assets/vue/admin/ChapterListDialog.vue'
import EditUserDialog from '@/assets/vue/admin/EditUserDialog.vue'
import SeriesScheduleDialog from '@/assets/vue/admin/SeriesScheduleDialog.vue'
import ConfirmDialog from '@/assets/vue/admin/ConfirmDialog.vue'

type Pagination = {
  page: number
  pageSize: number
  totalEntries: number
  totalPages: number
  hasPrevious: boolean
  hasNext: boolean
}

const props = defineProps<{
  seriesRows: SeriesRow[]
  pagination: Pagination
  query: string
  pageSize: number
  userRows: UserRow[]
  userPagination: Pagination
  userQuery: string
  userPageSize: number
  tags: Array<{ id: number; name: string }>
  coverUpload?: any
  reportRows: ReportRow[]
  reportPagination: Pagination
  reportStatus: string
  chapterRows: ChapterRow[]
  chapterPagination: Pagination
  chapterSeriesId: number | null
  chapterSeriesTitle: string | null
  auditRows: AuditRow[]
  auditPagination: Pagination
  auditAction: string
  auditTargetType: string
}>()

const live = useLiveVue()

const activeTab = ref<'series' | 'users' | 'reports' | 'audit'>('series')

// Series search
const searchQuery = ref(props.query ?? '')
watch(
  () => props.query,
  v => {
    if (v !== searchQuery.value) searchQuery.value = v
  },
)

const debouncedSearch = useDebounceFn((value: string) => {
  live.pushEvent('admin:search', { q: value })
}, 300)
watch(searchQuery, v => debouncedSearch(v))

// Users search
const userSearchQuery = ref(props.userQuery ?? '')
watch(
  () => props.userQuery,
  v => {
    if (v !== userSearchQuery.value) userSearchQuery.value = v
  },
)

const debouncedUsersSearch = useDebounceFn((value: string) => {
  live.pushEvent('admin:users_search', { q: value })
}, 300)
watch(userSearchQuery, v => debouncedUsersSearch(v))

function onPageSizeChange(event: Event) {
  const size = Number.parseInt((event.target as HTMLSelectElement).value, 10)
  live.pushEvent('admin:page_size_change', { page_size: size })
}

function onUserPageSizeChange(event: Event) {
  const size = Number.parseInt((event.target as HTMLSelectElement).value, 10)
  live.pushEvent('admin:users_page_size_change', { page_size: size })
}

function goToPage(page: number) {
  live.pushEvent('admin:page_change', { page })
}

function goToUserPage(page: number) {
  live.pushEvent('admin:users_page_change', { page })
}

function clearSearch() {
  searchQuery.value = ''
}

function clearUserSearch() {
  userSearchQuery.value = ''
}

const pageSizeOptions = [25, 50, 75, 100] as const

const showTagsDialog = ref(false)
const showAddSeriesDialog = ref(false)
const reportStatus = ref(props.reportStatus ?? 'all')

watch(
  () => props.reportStatus,
  v => {
    if (v !== reportStatus.value) reportStatus.value = v
  },
)

const showDeleteTagDialog = ref(false)
const tagPendingDelete = ref<{ id: number; name: string } | null>(null)

function handleAddTag(name: string) {
  live.pushEvent('admin:add_tag', { name })
}

function handleRemoveTag(id: number) {
  const tag = props.tags.find(t => t.id === id)
  tagPendingDelete.value = { id, name: tag?.name ?? `#${id}` }
  showDeleteTagDialog.value = true
}

function confirmDeleteTag() {
  if (!tagPendingDelete.value) return
  live.pushEvent('admin:remove_tag', { id: tagPendingDelete.value.id })
  showDeleteTagDialog.value = false
  tagPendingDelete.value = null
}

function handleCreateSeries(data: {
  title: string
  originalTitle: string
  authorInput: string
  authors: string[]
  description: string
  sourceUrl: string
  selectedTagIds: number[]
  coverFileName: string | null
}) {
  live.pushEvent('admin:create_series', data)
  showAddSeriesDialog.value = false
}

function onReportStatusChange(event: Event) {
  const status = (event.target as HTMLSelectElement).value
  live.pushEvent('admin:reports_status_change', { status })
}

function goToReportPage(page: number) {
  live.pushEvent('admin:reports_page_change', { page })
}

function onReportPageSizeChange(event: Event) {
  const size = Number.parseInt((event.target as HTMLSelectElement).value, 10)
  live.pushEvent('admin:reports_page_size_change', { page_size: size })
}

function handleResolveReport(id: number) {
  live.pushEvent('admin:resolve_report', { id })
}

function handleRejectReport(id: number) {
  live.pushEvent('admin:reject_report', { id })
}

// ---- Audit ----
const auditAction = ref(props.auditAction ?? 'all')
const auditTargetType = ref(props.auditTargetType ?? 'all')

watch(
  () => props.auditAction,
  (v) => { if (v !== auditAction.value) auditAction.value = v },
)

watch(
  () => props.auditTargetType,
  (v) => { if (v !== auditTargetType.value) auditTargetType.value = v },
)

function onAuditActionChange(event: Event) {
  const v = (event.target as HTMLSelectElement).value
  live.pushEvent('admin:audit_filter_change', { action: v, target_type: auditTargetType.value })
}

function onAuditTargetTypeChange(event: Event) {
  const v = (event.target as HTMLSelectElement).value
  live.pushEvent('admin:audit_filter_change', { action: auditAction.value, target_type: v })
}

function goToAuditPage(page: number) {
  live.pushEvent('admin:audit_page_change', { page })
}

function onAuditPageSizeChange(event: Event) {
  const size = Number.parseInt((event.target as HTMLSelectElement).value, 10)
  live.pushEvent('admin:audit_page_size_change', { page_size: size })
}

// ---- Chapter dialog state ----
const showChaptersDialog = ref(false)
const showScheduleDialog = ref(false)
const scheduleSeries = ref<SeriesRow | null>(null)

function handleOpenChapters(row: SeriesRow) {
  live.pushEvent('admin:list_chapters', { series_id: row.id, page: 1, page_size: 25 })
  showChaptersDialog.value = true
}

function handleEditSchedule(row: SeriesRow) {
  scheduleSeries.value = row
  showScheduleDialog.value = true
}

const showDeleteSeriesDialog = ref(false)
const seriesPendingDelete = ref<SeriesRow | null>(null)
const showArchiveDialog = ref(false)
const seriesPendingArchive = ref<SeriesRow | null>(null)
const showUnarchiveDialog = ref(false)
const seriesPendingUnarchive = ref<SeriesRow | null>(null)

function handleDeleteSeries(row: SeriesRow) {
  seriesPendingDelete.value = row
  showDeleteSeriesDialog.value = true
}

function confirmDeleteSeries() {
  if (!seriesPendingDelete.value) return
  live.pushEvent('admin:delete_series', { id: seriesPendingDelete.value.id })
  showDeleteSeriesDialog.value = false
  seriesPendingDelete.value = null
}

function handleArchiveSeries(row: SeriesRow) {
  seriesPendingArchive.value = row
  showArchiveDialog.value = true
}
function confirmArchiveSeries() {
  if (!seriesPendingArchive.value) return
  live.pushEvent('admin:archive_series', { id: seriesPendingArchive.value.id })
  showArchiveDialog.value = false
  seriesPendingArchive.value = null
}

function handleUnarchiveSeries(row: SeriesRow) {
  seriesPendingUnarchive.value = row
  showUnarchiveDialog.value = true
}
function confirmUnarchiveSeries() {
  if (!seriesPendingUnarchive.value) return
  live.pushEvent('admin:unarchive_series', { id: seriesPendingUnarchive.value.id })
  showUnarchiveDialog.value = false
  seriesPendingUnarchive.value = null
}

function handleChapterPageChange(page: number) {
  live.pushEvent('admin:chapters_page_change', { page })
}

function handleChapterPageSizeChange(size: number) {
  live.pushEvent('admin:chapters_page_size_change', { page_size: size })
}

const showDeleteChapterDialog = ref(false)
const chapterPendingDelete = ref<ChapterRow | null>(null)

function handleDeleteChapter(row: ChapterRow) {
  chapterPendingDelete.value = row
  showDeleteChapterDialog.value = true
}

function confirmDeleteChapter() {
  if (!chapterPendingDelete.value) return
  live.pushEvent('admin:delete_chapter', { id: chapterPendingDelete.value.id })
  showDeleteChapterDialog.value = false
  chapterPendingDelete.value = null
}

function handleRepairChapter(payload: { id: number; newSourceUrl: string | null }) {
  live.pushEvent('admin:repair_chapter', { id: payload.id, new_source_url: payload.newSourceUrl })
}

function handleChapterRefresh() {
  if (props.chapterSeriesId) {
    live.pushEvent('admin:list_chapters', { series_id: props.chapterSeriesId, page: props.chapterPagination.page, page_size: props.chapterPagination.pageSize })
  }
}

function handleSaveSchedule(data: { id: number; publicationStatus: string; manualInterval: string | null }) {
  live.pushEvent('admin:update_series_schedule', { id: data.id, publication_status: data.publicationStatus, manual_check_interval_minutes: data.manualInterval })
  showScheduleDialog.value = false
}

// ---- User dialog state ----
const showEditUserDialog = ref(false)
const editingUser = ref<UserRow | null>(null)
const showDeleteUserDialog = ref(false)
const userPendingDelete = ref<UserRow | null>(null)

function handleEditUser(row: UserRow) {
  editingUser.value = row
  showEditUserDialog.value = true
}

function handleDeleteUser(row: UserRow) {
  userPendingDelete.value = row
  showDeleteUserDialog.value = true
}

function confirmDeleteUser() {
  if (!userPendingDelete.value) return
  live.pushEvent('admin:delete_user', { id: userPendingDelete.value.id })
  showDeleteUserDialog.value = false
  userPendingDelete.value = null
}

function handleSaveUser(data: { id: number; username: string; email: string; role: string; active: boolean }) {
  live.pushEvent('admin:update_user', { id: data.id, username: data.username, email: data.email, role: data.role, active: data.active })
  showEditUserDialog.value = false
}

const seriesRowsForTable = computed(() => [...(props.seriesRows ?? [])])
const userRowsForTable = computed(() => [...(props.userRows ?? [])])
const reportRowsForTable = computed(() => [...(props.reportRows ?? [])])
const chapterRowsForTable = computed(() => [...(props.chapterRows ?? [])])
const auditRowsForTable = computed(() => [...(props.auditRows ?? [])])

// Keep chapter dialog open when props update after delete/repair? No auto-close
watch(() => props.chapterRows, () => {
  // keep dialog open, no action
})

// Folder tabs
// Active overlaps card border via -mb-px + border-b-card.
const tabBase =
  'relative px-4 py-2.5 text-sm font-medium rounded-t-lg border transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring'
const tabActive =
  'bg-card border-border text-foreground shadow-sm border-b-card -mb-px z-10'
const tabInactive =
  'bg-muted/30 border-transparent text-muted-foreground hover:text-foreground hover:bg-muted'
</script>

<template>
  <div class="mx-auto max-w-6xl w-full px-4 py-6">
    <!-- Title -->
    <h1 class="text-2xl md:text-3xl font-bold text-center tracking-tight mb-6">Admin Dashboard</h1>

    <!-- Folder tabs — differentiated: more padding, no blue, softer -->
    <div class="flex gap-1.5 px-1">
      <button
        type="button"
        :class="[tabBase, activeTab === 'series' ? tabActive : tabInactive]"
        class="border-b-0"
        :aria-selected="activeTab === 'series'"
        role="tab"
        @click="activeTab = 'series'"
      >
        Series
      </button>
      <button
        type="button"
        :class="[tabBase, activeTab === 'users' ? tabActive : tabInactive]"
        class="border-b-0"
        :aria-selected="activeTab === 'users'"
        role="tab"
        @click="activeTab = 'users'"
      >
        Users
      </button>
      <button
        type="button"
        :class="[tabBase, activeTab === 'reports' ? tabActive : tabInactive]"
        class="border-b-0"
        :aria-selected="activeTab === 'reports'"
        role="tab"
        @click="activeTab = 'reports'"
      >
        Reports
      </button>
      <button
        type="button"
        :class="[tabBase, activeTab === 'audit' ? tabActive : tabInactive]"
        class="border-b-0"
        :aria-selected="activeTab === 'audit'"
        role="tab"
        @click="activeTab = 'audit'"
      >
        Audit
      </button>
    </div>

    <!-- Card — single straight border, no double rounded (request: straight line only) -->
    <div class="border bg-card shadow-sm overflow-hidden -mt-px">
      <!-- Series content -->
      <div v-show="activeTab === 'series'">
        <!-- Header — more airy, not dark slate -->
        <div class="flex items-center justify-between px-5 py-4 border-b bg-muted/20">
          <h2 class="text-base font-semibold tracking-tight">Series</h2>
          <div class="flex items-center gap-2">
            <Button variant="outline" size="sm" class="gap-1.5 h-8" @click="showTagsDialog = true">
              <Tag class="size-3.5" />
              Tags
            </Button>
            <Button size="sm" class="gap-1.5 h-8" @click="showAddSeriesDialog = true">
              <Plus class="size-3.5" />
              Add Series
            </Button>
          </div>
        </div>

        <!-- Controls — placeholder text, softer -->
        <div class="flex flex-col sm:flex-row gap-3 items-center justify-between px-4 py-4">
          <div class="relative w-full sm:w-72">
            <Search class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
            <Input
              v-model="searchQuery"
              placeholder="Search by title…"
              class="pl-8 h-8 rounded-lg"
              aria-label="Search series"
            />
            <button
              v-if="searchQuery"
              type="button"
              class="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-muted-foreground hover:text-foreground"
              aria-label="Clear search"
              @click="clearSearch"
            >
              ✕
            </button>
          </div>

          <select
            :value="String(pageSize)"
            class="flex h-8 w-[72px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
            aria-label="Rows per page"
            @change="onPageSizeChange"
          >
            <option v-for="n in pageSizeOptions" :key="n" :value="String(n)">{{ n }}</option>
          </select>
        </div>

        <!-- Table — use computed copy so LiveVue in-place `splice` triggers TanStack -->
        <AdminSeriesTable :data="seriesRowsForTable" @openChapters="handleOpenChapters" @editSchedule="handleEditSchedule" @deleteSeries="handleDeleteSeries" @archiveSeries="handleArchiveSeries" @unarchiveSeries="handleUnarchiveSeries" />

        <!-- Pagination — softer, more spacing -->
        <div class="flex flex-col sm:flex-row items-center justify-between gap-3 px-4 py-4 border-t bg-muted/10">
          <p class="text-xs text-muted-foreground">
            <template v-if="pagination.totalEntries === 0"> No results </template>
            <template v-else>
              Showing {{ (pagination.page - 1) * pagination.pageSize + 1 }}–{{
                Math.min(pagination.page * pagination.pageSize, pagination.totalEntries)
              }}
              of {{ pagination.totalEntries }} series
            </template>
          </p>
          <div class="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              :disabled="!pagination.hasPrevious"
              class="h-7"
              @click="goToPage(pagination.page - 1)"
            >
              Previous
            </Button>
            <span class="text-xs tabular-nums px-2 py-1 rounded bg-muted"> Page {{ pagination.page }} of {{ pagination.totalPages }} </span>
            <Button
              variant="ghost"
              size="sm"
              :disabled="!pagination.hasNext"
              class="h-7"
              @click="goToPage(pagination.page + 1)"
            >
              Next
            </Button>
          </div>
        </div>
      </div>

      <!-- Users content -->
      <div v-show="activeTab === 'users'">
        <div class="flex items-center justify-between px-5 py-4 border-b bg-muted/20">
          <h2 class="text-base font-semibold tracking-tight">Users</h2>
          <div class="flex items-center gap-2">
            <span class="text-xs text-muted-foreground hidden sm:inline">
              {{ userPagination.totalEntries }} total
            </span>
            <Button variant="outline" size="sm" class="h-8" disabled title="Bulk actions coming soon">
              Manage
            </Button>
          </div>
        </div>

        <div class="flex flex-col sm:flex-row gap-3 items-center justify-between px-4 py-4">
          <div class="relative w-full sm:w-72">
            <Search class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
            <Input
              v-model="userSearchQuery"
              placeholder="Search users…"
              class="pl-8 h-8 rounded-lg"
              aria-label="Search users"
            />
            <button
              v-if="userSearchQuery"
              type="button"
              class="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-muted-foreground hover:text-foreground"
              aria-label="Clear users search"
              @click="clearUserSearch"
            >
              ✕
            </button>
          </div>
          <select
            :value="String(userPageSize)"
            class="flex h-8 w-[72px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
            aria-label="Rows per page"
            @change="onUserPageSizeChange"
          >
            <option v-for="n in pageSizeOptions" :key="n" :value="String(n)">{{ n }}</option>
          </select>
        </div>

        <AdminUsersTable :data="userRowsForTable" @edit="handleEditUser" @delete="handleDeleteUser" />

        <div class="flex flex-col sm:flex-row items-center justify-between gap-3 px-4 py-4 border-t bg-muted/10">
          <p class="text-xs text-muted-foreground">
            <template v-if="userPagination.totalEntries === 0"> No results </template>
            <template v-else>
              Showing {{ (userPagination.page - 1) * userPagination.pageSize + 1 }}–{{
                Math.min(userPagination.page * userPagination.pageSize, userPagination.totalEntries)
              }}
              of {{ userPagination.totalEntries }} users
            </template>
          </p>
          <div class="flex items-center gap-2">
            <Button variant="ghost" size="sm" :disabled="!userPagination.hasPrevious" class="h-7" @click="goToUserPage(userPagination.page - 1)">
              Previous
            </Button>
            <span class="text-xs tabular-nums px-2 py-1 rounded bg-muted"> Page {{ userPagination.page }} of {{ userPagination.totalPages }} </span>
            <Button variant="ghost" size="sm" :disabled="!userPagination.hasNext" class="h-7" @click="goToUserPage(userPagination.page + 1)">
              Next
            </Button>
          </div>
        </div>
      </div>

      <!-- Reports — TanStack table with status filter and resolve/reject -->
      <div v-show="activeTab === 'reports'">
        <div class="flex items-center justify-between px-5 py-4 border-b bg-muted/20">
          <h2 class="text-base font-semibold tracking-tight">Reports</h2>
          <div class="flex items-center gap-2">
            <span class="text-xs text-muted-foreground hidden sm:inline">{{ reportPagination.totalEntries }} total</span>
            <select
              :value="reportStatus"
              class="flex h-8 w-[130px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
              aria-label="Filter by status"
              @change="onReportStatusChange"
            >
              <option value="all">All statuses</option>
              <option value="pending">Pending</option>
              <option value="resolved">Resolved</option>
              <option value="rejected">Rejected</option>
            </select>
          </div>
        </div>

        <div class="flex flex-col sm:flex-row gap-3 items-center justify-between px-4 py-4">
          <p class="text-xs text-muted-foreground">Moderation queue — resolve or reject pending reports</p>
          <select
            :value="String(reportPagination.pageSize)"
            class="flex h-8 w-[72px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
            aria-label="Rows per page"
            @change="onReportPageSizeChange"
          >
            <option v-for="n in pageSizeOptions" :key="n" :value="String(n)">{{ n }}</option>
          </select>
        </div>

        <AdminReportsTable :data="reportRowsForTable" @resolve="handleResolveReport" @reject="handleRejectReport" />

        <div class="flex flex-col sm:flex-row items-center justify-between gap-3 px-4 py-4 border-t bg-muted/10">
          <p class="text-xs text-muted-foreground">
            <template v-if="reportPagination.totalEntries === 0"> No reports </template>
            <template v-else>
              Showing {{ (reportPagination.page - 1) * reportPagination.pageSize + 1 }}–{{
                Math.min(reportPagination.page * reportPagination.pageSize, reportPagination.totalEntries)
              }}
              of {{ reportPagination.totalEntries }} reports
            </template>
          </p>
          <div class="flex items-center gap-2">
            <Button variant="ghost" size="sm" :disabled="!reportPagination.hasPrevious" class="h-7" @click="goToReportPage(reportPagination.page - 1)">
              Previous
            </Button>
            <span class="text-xs tabular-nums px-2 py-1 rounded bg-muted"> Page {{ reportPagination.page }} of {{ reportPagination.totalPages }} </span>
            <Button variant="ghost" size="sm" :disabled="!reportPagination.hasNext" class="h-7" @click="goToReportPage(reportPagination.page + 1)">
              Next
            </Button>
          </div>
        </div>
      </div>

      <!-- Audit — traceable admin actions -->
      <div v-show="activeTab === 'audit'">
        <div class="flex items-center justify-between px-5 py-4 border-b bg-muted/20">
          <h2 class="text-base font-semibold tracking-tight">Audit Logs</h2>
          <div class="flex items-center gap-2">
            <span class="text-xs text-muted-foreground hidden sm:inline">{{ auditPagination.totalEntries }} total</span>
            <select
              :value="auditAction"
              class="flex h-8 w-[160px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
              aria-label="Filter by action"
              @change="onAuditActionChange"
            >
              <option value="all">All actions</option>
              <option value="category.create">category.create</option>
              <option value="category.delete">category.delete</option>
              <option value="series.create">series.create</option>
              <option value="series.delete">series.delete</option>
              <option value="series.archive">series.archive</option>
              <option value="series.unarchive">series.unarchive</option>
              <option value="series.update_schedule">series.update_schedule</option>
              <option value="chapter.delete">chapter.delete</option>
              <option value="chapter.repair">chapter.repair</option>
              <option value="user.update">user.update</option>
              <option value="user.delete">user.delete</option>
              <option value="report.resolve">report.resolve</option>
              <option value="report.reject">report.reject</option>
            </select>
            <select
              :value="auditTargetType"
              class="flex h-8 w-[120px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
              aria-label="Filter by target"
              @change="onAuditTargetTypeChange"
            >
              <option value="all">All targets</option>
              <option value="category">category</option>
              <option value="series">series</option>
              <option value="chapter">chapter</option>
              <option value="user">user</option>
              <option value="report">report</option>
            </select>
          </div>
        </div>

        <div class="flex flex-col sm:flex-row gap-3 items-center justify-between px-4 py-4">
          <p class="text-xs text-muted-foreground">Traceable history of every mutating admin action — actor, target, IP and metadata.</p>
          <select
            :value="String(auditPagination.pageSize)"
            class="flex h-8 w-[72px] items-center justify-between rounded-lg border bg-card px-2.5 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
            aria-label="Rows per page"
            @change="onAuditPageSizeChange"
          >
            <option v-for="n in pageSizeOptions" :key="n" :value="String(n)">{{ n }}</option>
          </select>
        </div>

        <AdminAuditTable :data="auditRowsForTable" />

        <div class="flex flex-col sm:flex-row items-center justify-between gap-3 px-4 py-4 border-t bg-muted/10">
          <p class="text-xs text-muted-foreground">
            <template v-if="auditPagination.totalEntries === 0"> No audit logs </template>
            <template v-else>
              Showing {{ (auditPagination.page - 1) * auditPagination.pageSize + 1 }}–{{
                Math.min(auditPagination.page * auditPagination.pageSize, auditPagination.totalEntries)
              }} of {{ auditPagination.totalEntries }} logs
            </template>
          </p>
          <div class="flex items-center gap-2">
            <Button variant="ghost" size="sm" :disabled="!auditPagination.hasPrevious" class="h-7" @click="goToAuditPage(auditPagination.page - 1)"> Previous </Button>
            <span class="text-xs tabular-nums px-2 py-1 rounded bg-muted"> Page {{ auditPagination.page }} of {{ auditPagination.totalPages }} </span>
            <Button variant="ghost" size="sm" :disabled="!auditPagination.hasNext" class="h-7" @click="goToAuditPage(auditPagination.page + 1)"> Next </Button>
          </div>
        </div>
      </div>
    </div>

    <ManageTagsDialog
      :open="showTagsDialog"
      :tags="tags"
      @update:open="showTagsDialog = $event"
      @addTag="handleAddTag"
      @removeTag="handleRemoveTag"
    />
    <AddSeriesDialog
      :open="showAddSeriesDialog"
      :tags="tags"
      :coverUpload="coverUpload"
      @update:open="showAddSeriesDialog = $event"
      @createSeries="handleCreateSeries"
    />
    <ChapterListDialog
      :open="showChaptersDialog"
      :seriesTitle="chapterSeriesTitle"
      :seriesId="chapterSeriesId"
      :chapters="chapterRowsForTable"
      :pagination="chapterPagination"
      @update:open="showChaptersDialog = $event"
      @deleteChapter="handleDeleteChapter"
      @repairChapter="handleRepairChapter"
      @pageChange="handleChapterPageChange"
      @pageSizeChange="handleChapterPageSizeChange"
      @refresh="handleChapterRefresh"
    />
    <EditUserDialog
      :open="showEditUserDialog"
      :user="editingUser"
      @update:open="showEditUserDialog = $event"
      @save="handleSaveUser"
    />
    <SeriesScheduleDialog
      :open="showScheduleDialog"
      :series="scheduleSeries"
      @update:open="showScheduleDialog = $event"
      @save="handleSaveSchedule"
    />
    <ConfirmDialog
      :open="showDeleteSeriesDialog"
      title="Are you sure to delete series?"
      :description="seriesPendingDelete ? `This action will permanently mark the series '${seriesPendingDelete.title}' for deletion. This cannot be undone.` : 'This action cannot be undone.'"
      confirm-label="Confirm"
      variant="destructive"
      @update:open="showDeleteSeriesDialog = $event"
      @confirm="confirmDeleteSeries"
      @cancel="showDeleteSeriesDialog = false"
    />
    <ConfirmDialog
      :open="showDeleteUserDialog"
      title="Are you sure to delete user?"
      :description="userPendingDelete ? `This action will permanently delete user '${userPendingDelete.username}' (${userPendingDelete.email}). This cannot be undone.` : 'This action cannot be undone.'"
      confirm-label="Confirm"
      variant="destructive"
      @update:open="showDeleteUserDialog = $event"
      @confirm="confirmDeleteUser"
      @cancel="showDeleteUserDialog = false"
    />
    <ConfirmDialog
      :open="showDeleteChapterDialog"
      title="Are you sure to delete chapter?"
      :description="chapterPendingDelete ? `This action will permanently delete chapter '${chapterPendingDelete.displayNumber}' (${chapterPendingDelete.chapterKey}) and its images from storage. This cannot be undone.` : 'This action cannot be undone.'"
      confirm-label="Confirm"
      variant="destructive"
      @update:open="showDeleteChapterDialog = $event"
      @confirm="confirmDeleteChapter"
      @cancel="showDeleteChapterDialog = false"
    />
    <ConfirmDialog
      :open="showDeleteTagDialog"
      title="Are you sure to delete tag?"
      :description="tagPendingDelete ? `This action will permanently delete tag '${tagPendingDelete.name}'. Series using this tag will be untagged.` : 'This action cannot be undone.'"
      confirm-label="Confirm"
      variant="destructive"
      @update:open="showDeleteTagDialog = $event"
      @confirm="confirmDeleteTag"
      @cancel="showDeleteTagDialog = false"
    />
    <ConfirmDialog
      :open="showArchiveDialog"
      title="Are you sure to archive series?"
      :description="seriesPendingArchive ? `This action will archive series '${seriesPendingArchive.title}' — it will be delisted from user UI instantly but kept in DB/storage until hard-deleted one-by-one.` : 'This action will archive the series.'"
      confirm-label="Confirm"
      variant="default"
      @update:open="showArchiveDialog = $event"
      @confirm="confirmArchiveSeries"
      @cancel="showArchiveDialog = false"
    />
    <ConfirmDialog
      :open="showUnarchiveDialog"
      title="Are you sure to unarchive series?"
      :description="seriesPendingUnarchive ? `This action will unarchive series '${seriesPendingUnarchive.title}' — it will be visible again and rescheduled.` : 'This action will unarchive the series.'"
      confirm-label="Confirm"
      variant="default"
      @update:open="showUnarchiveDialog = $event"
      @confirm="confirmUnarchiveSeries"
      @cancel="showUnarchiveDialog = false"
    />

    <p class="text-center text-xs text-muted-foreground pt-3">
      CrysA admin — folder tabs are client state; tables are TanStack + server filtering.
    </p>
  </div>
</template>
