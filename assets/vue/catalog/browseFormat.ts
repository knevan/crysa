const COVER_GRADIENTS: Array<[string, string]> = [
  ['#7F1D1D', '#EA580C'],
  ['#831843', '#F472B6'],
  ['#0C4A6E', '#38BDF8'],
  ['#1E1B4B', '#818CF8'],
  ['#14532D', '#4ADE80'],
]

export function gradientFor(id: number): [string, string] {
  const idx = Math.abs(id) % COVER_GRADIENTS.length
  return COVER_GRADIENTS[idx] ?? ['#0F172A', '#475569']
}

export function gradientStyle(id: number): { background: string } {
  const [from, to] = gradientFor(id)
  return { background: `linear-gradient(135deg, ${from}, ${to})` }
}

export function formatViews(count: number): string {
  return (count || 0).toLocaleString('en-US')
}
