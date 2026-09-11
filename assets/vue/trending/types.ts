export type TrendingPeriod = 'hour' | 'day' | 'week' | 'month'

export interface TrendingItem {
  id: number
  title: string
  slug: string
  coverUrl: string | null
}

export interface TrendingList {
  items: TrendingItem[]
  computedAt: string
}

export type TrendingLists = Record<TrendingPeriod, TrendingList>

export const TRENDING_PERIODS: TrendingPeriod[] = ['hour', 'day', 'week', 'month']
