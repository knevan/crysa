<script setup lang="ts">
import { ref, watch } from 'vue'
import { useDebounceFn } from '@vueuse/core'
import { useLiveVue } from 'live_vue'
import { Search, Tag, Plus } from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import AdminSeriesTable, { type SeriesRow } from '@/assets/vue/admin/AdminSeriesTable.vue'
import AdminUsersTable, { type UserRow } from '@/assets/vue/admin/AdminUsersTable.vue'
import AdminReportsTable, { type ReportRow } from '@/assets/vue/admin/AdminReportsTable.vue'
import ManageTagsDialog from '@/assets/vue/admin/ManageTagsDialog.vue'
import AddSeriesDialog from '@/assets/vue/admin/AddSeriesDialog.vue'

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
}>()

const live = useLiveVue()

const activeTab = ref<'series' | 'users' | 'reports'>('series')

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

function handleAddTag(name: string) {
  live.pushEvent('admin:add_tag', { name })
}
function handleRemoveTag(id: number) {
  live.pushEvent('admin:remove_tag', { id })
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

// Folder tabs — differentiated from Castra: neutral border/shadow, not blue.
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

        <!-- Table -->
        <AdminSeriesTable :data="seriesRows" />

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

        <AdminUsersTable :data="userRows" />

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

        <AdminReportsTable :data="reportRows" @resolve="handleResolveReport" @reject="handleRejectReport" />

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

    <p class="text-center text-xs text-muted-foreground pt-3">
      CrysA admin — folder tabs are client state; tables are TanStack + server filtering.
    </p>
  </div>
</template>
