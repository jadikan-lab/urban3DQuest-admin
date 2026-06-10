#!/usr/bin/env node

/**
 * Backfill optimizer for legacy treasure photos stored in Supabase bucket `photos`.
 *
 * What it does:
 * 1) Reads `treasures.photo_url` values from PostgREST.
 * 2) For each public storage URL, fetches a transformed WebP rendition.
 * 3) Uploads the optimized file back to bucket `photos` with a `.webp` key.
 * 4) Rewrites `treasures.photo_url` to the optimized public URL(s).
 *
 * Required env:
 * - SUPABASE_URL
 * - SUPABASE_SERVICE_ROLE_KEY
 *
 * Optional env:
 * - IMG_WIDTH (default 1200)
 * - IMG_QUALITY (default 72)
 *
 * Flags:
 * - --dry-run    Print planned updates without writing
 * - --limit N    Process at most N treasures
 */

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const limitIdx = args.indexOf('--limit');
const limit = limitIdx >= 0 ? Math.max(0, Number(args[limitIdx + 1] || '0')) : 0;

const SUPABASE_URL = String(process.env.SUPABASE_URL || '').trim().replace(/\/$/, '');
const SERVICE_KEY = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const IMG_WIDTH = String(process.env.IMG_WIDTH || '1200').trim();
const IMG_QUALITY = String(process.env.IMG_QUALITY || '72').trim();

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('Missing env. Required: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}

const REST_HEADERS = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  Accept: 'application/json'
};

function parsePhotoUrls(raw) {
  const s = String(raw || '').trim();
  if (!s) return [];
  if (s.startsWith('[')) {
    try {
      const arr = JSON.parse(s);
      return Array.isArray(arr) ? arr.filter(Boolean).map(String) : [];
    } catch {
      return [];
    }
  }
  return [s];
}

function serializePhotoUrls(urls) {
  if (!Array.isArray(urls) || urls.length === 0) return '';
  return urls.length === 1 ? urls[0] : JSON.stringify(urls);
}

function extractPublicPhotoKey(url) {
  try {
    const u = new URL(String(url || '').trim());
    const marker = '/storage/v1/object/public/photos/';
    const idx = u.pathname.indexOf(marker);
    if (idx < 0) return null;
    const encodedKey = u.pathname.slice(idx + marker.length);
    if (!encodedKey) return null;
    return decodeURIComponent(encodedKey);
  } catch {
    return null;
  }
}

function replaceExtWithWebp(key) {
  return key.replace(/\.[a-zA-Z0-9]+$/, '') + '.webp';
}

function buildRenderUrl(key) {
  const safeKey = key.split('/').map(encodeURIComponent).join('/');
  return `${SUPABASE_URL}/storage/v1/render/image/public/photos/${safeKey}?width=${encodeURIComponent(IMG_WIDTH)}&quality=${encodeURIComponent(IMG_QUALITY)}&format=webp`;
}

function buildObjectUploadUrl(key) {
  const safeKey = key.split('/').map(encodeURIComponent).join('/');
  return `${SUPABASE_URL}/storage/v1/object/photos/${safeKey}`;
}

function buildPublicUrl(key) {
  const safeKey = key.split('/').map(encodeURIComponent).join('/');
  return `${SUPABASE_URL}/storage/v1/object/public/photos/${safeKey}`;
}

async function fetchTreasures() {
  const url = `${SUPABASE_URL}/rest/v1/treasures?select=id,photo_url&photo_url=not.is.null`;
  const res = await fetch(url, { headers: REST_HEADERS });
  if (!res.ok) throw new Error(`fetch treasures failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function uploadOptimizedPhoto(targetKey, bytes) {
  const res = await fetch(buildObjectUploadUrl(targetKey), {
    method: 'POST',
    headers: {
      ...REST_HEADERS,
      'Content-Type': 'image/webp',
      'x-upsert': 'true'
    },
    body: bytes
  });
  if (!res.ok) throw new Error(`upload failed (${targetKey}): ${res.status} ${await res.text()}`);
}

async function patchTreasurePhotoUrl(id, photoUrlValue) {
  const url = `${SUPABASE_URL}/rest/v1/treasures?id=eq.${encodeURIComponent(id)}`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: {
      ...REST_HEADERS,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal'
    },
    body: JSON.stringify({ photo_url: photoUrlValue })
  });
  if (!res.ok) throw new Error(`patch treasure failed (${id}): ${res.status} ${await res.text()}`);
}

async function main() {
  const rows = await fetchTreasures();
  const list = limit > 0 ? rows.slice(0, limit) : rows;

  let scanned = 0;
  let rewritten = 0;
  let skipped = 0;

  for (const row of list) {
    scanned += 1;
    const urls = parsePhotoUrls(row.photo_url);
    if (!urls.length) {
      skipped += 1;
      continue;
    }

    let changed = false;
    const nextUrls = [];

    for (const url of urls) {
      const key = extractPublicPhotoKey(url);
      if (!key) {
        nextUrls.push(url);
        continue;
      }

      const nextKey = replaceExtWithWebp(key);
      const nextPublicUrl = buildPublicUrl(nextKey);

      if (url === nextPublicUrl) {
        nextUrls.push(url);
        continue;
      }

      changed = true;
      nextUrls.push(nextPublicUrl);

      if (dryRun) continue;

      const renderRes = await fetch(buildRenderUrl(key));
      if (!renderRes.ok) {
        throw new Error(`render failed (${key}): ${renderRes.status} ${await renderRes.text()}`);
      }
      const bytes = await renderRes.arrayBuffer();
      await uploadOptimizedPhoto(nextKey, bytes);
    }

    if (!changed) {
      skipped += 1;
      continue;
    }

    rewritten += 1;
    const nextValue = serializePhotoUrls(nextUrls);
    if (!dryRun) await patchTreasurePhotoUrl(row.id, nextValue);
    console.log(`${dryRun ? '[dry-run] ' : ''}${row.id} -> optimized photo_url updated`);
  }

  console.log(`Done. scanned=${scanned} rewritten=${rewritten} skipped=${skipped} dryRun=${dryRun}`);
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
