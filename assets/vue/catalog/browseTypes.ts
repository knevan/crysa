export type BrowseChapter = {
  displayNumber: string
  chapterKey: string
}

export type BrowseEntry = {
  id: number
  title: string
  slug: string
  description: string | null
  coverUrl: string | null
  viewCount: number
  ratingAverage: number | null
  ratingCount: number
  trending: boolean
  firstChapter: BrowseChapter | null
}

export type BrowseCategory = {
  id: number
  name: string
}

export type BrowsePagination = {
  page: number
  pageSize: number
  totalEntries: number
  totalPages: number
  hasPrevious: boolean
  hasNext: boolean
}

export type TagState = 'none' | 'include' | 'exclude'

export const SORT_OPTIONS: Array<{ value: string; label: string }> = [
  { value: 'latest_updates', label: 'Last Updated' },
  { value: 'new', label: 'Newest' },
  { value: 'most_viewed', label: 'Most Viewed' },
  { value: 'title', label: 'Title' },
]

export const STATUS_OPTIONS: Array<{ value: string; label: string }> = [
  { value: '', label: 'All' },
  { value: 'ongoing', label: 'Ongoing' },
  { value: 'completed', label: 'Completed' },
  { value: 'hiatus', label: 'Hiatus' },
  { value: 'discontinued', label: 'Discontinued' },
]
