/**
 * Overlay replacement for backend/src/pro/exa.ts.
 *
 * Swaps the Exa-backed implementation for a self-hosted SearXNG + direct
 * fetch. Keeps the `exaPlugin` export name, same routes (`/search`,
 * `/fetch-content`), same response shapes — so routes.ts and the frontend
 * need no changes.
 *
 * Env:
 *   SEARXNG_URL  Base URL of a SearXNG instance (default http://localhost:8080)
 */
import { safeErrorHandler } from '@/middleware/error-handling'
import { Elysia, t } from 'elysia'
import type { FetchContentResponse, SearchResponse } from './types'

const SEARXNG_URL = (process.env.SEARXNG_URL || 'http://localhost:8080').replace(/\/+$/, '')

const hashId = (url: string): string => {
  let h = 0
  for (let i = 0; i < url.length; i++) h = ((h << 5) - h + url.charCodeAt(i)) | 0
  return 'sx_' + (h >>> 0).toString(36)
}

const extractTitle = (html: string): string | null => {
  const m = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)
  return m ? decodeEntities(m[1].trim()) : null
}

const extractMeta = (html: string, name: string): string | null => {
  const patterns = [
    new RegExp(`<meta[^>]+(?:name|property)=["']${name}["'][^>]+content=["']([^"']+)["']`, 'i'),
    new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+(?:name|property)=["']${name}["']`, 'i'),
  ]
  for (const re of patterns) {
    const m = html.match(re)
    if (m) return decodeEntities(m[1])
  }
  return null
}

const decodeEntities = (s: string): string =>
  s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')

const stripHtml = (html: string): string => {
  let s = html.replace(/<(script|style|noscript|nav|footer|aside|svg|form|head)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ')
  s = s.replace(/<!--[\s\S]*?-->/g, ' ')
  s = s.replace(/<[^>]+>/g, ' ')
  s = decodeEntities(s)
  return s.replace(/\s+/g, ' ').trim()
}

export const exaPlugin = new Elysia({ name: 'exa' })
  .onError(safeErrorHandler)
  .post(
    '/search',
    async ({ body }): Promise<SearchResponse> => {
      const params = new URLSearchParams({
        q: body.query,
        format: 'json',
        safesearch: '0',
        categories: 'general,news',
      })
      let r: Response
      try {
        r = await fetch(`${SEARXNG_URL}/search?${params.toString()}`, {
          signal: AbortSignal.timeout(10_000),
        })
      } catch (e) {
        return { data: [], success: false, error: String(e) }
      }
      if (!r.ok) {
        return { data: [], success: false, error: `SearXNG HTTP ${r.status}` }
      }
      const data = (await r.json()) as { results?: unknown[] }
      const limit = body.max_results ?? 10
      const results = ((data.results ?? []) as Array<Record<string, unknown>>).slice(0, limit).map((it) => ({
        id: hashId(String(it.url ?? '')),
        url: String(it.url ?? ''),
        title: (it.title as string | null) ?? null,
        summary: (it.content as string | undefined) ?? undefined,
        favicon: null,
        image: (it.img_src as string | null) ?? null,
        author: (it.author as string | null) ?? null,
        publishedDate: (it.publishedDate as string | null) ?? null,
        score: typeof it.score === 'number' ? it.score : undefined,
      }))
      // Frontend type expects SearchResultData; cast through unknown to satisfy exa-js SearchResult<{}>.
      return { data: results as unknown as SearchResponse['data'], success: true }
    },
    {
      body: t.Object({
        query: t.String(),
        max_results: t.Optional(t.Number({ default: 10 })),
      }),
    },
  )
  .post(
    '/fetch-content',
    async ({ body }): Promise<FetchContentResponse> => {
      const defaultMaxChars = 16_000
      const hardCap = 64_000
      const minChars = 1_000
      const requestedMax = body.max_length ?? defaultMaxChars
      const maxCharacters = Math.min(Math.max(requestedMax, minChars), hardCap)

      let r: Response
      try {
        r = await fetch(body.url, {
          signal: AbortSignal.timeout(10_000),
          redirect: 'follow',
          headers: { 'User-Agent': 'thunderbolt-pro/1.0' },
        })
      } catch (e) {
        return { data: null, success: false, error: String(e) }
      }
      if (!r.ok) {
        return { data: null, success: false, error: `HTTP ${r.status}` }
      }
      const html = await r.text()
      const title = extractTitle(html)
      const image = extractMeta(html, 'og:image')
      const author = extractMeta(html, 'author') ?? extractMeta(html, 'article:author')
      const published = extractMeta(html, 'article:published_time') ?? extractMeta(html, 'og:updated_time')
      const text = stripHtml(html)

      const isTruncated = text.length >= maxCharacters
      const truncationHint =
        isTruncated && maxCharacters < hardCap
          ? `\n\n[Content truncated. Call fetch_content with max_length=${Math.min(maxCharacters * 2, hardCap)} for more.]`
          : ''

      return {
        data: {
          id: hashId(body.url),
          url: r.url || body.url,
          title,
          text: text.slice(0, maxCharacters) + truncationHint,
          isTruncated,
          favicon: null,
          image,
          author,
          publishedDate: published,
        } as unknown as NonNullable<FetchContentResponse['data']>,
        success: true,
      }
    },
    {
      body: t.Object({
        url: t.String(),
        max_length: t.Optional(t.Number()),
      }),
    },
  )
