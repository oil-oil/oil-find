import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { changelogTitle, releases } from '../content/releases';

describe('updates and release notes', () => {
  it('includes the exact bilingual 1.6.0 external-drive announcement', () => {
    expect(releases.find(release => release.version === '1.6.0')?.notes).toEqual({"zh": ["外置磁盘搜索现在免费：插上就建立索引并实时更新，在设置的「外置磁盘」里可以逐个关闭。", "Pro 保留「拔掉后也能搜到」，并继续提供图片和文档内容搜索。", "Pro 激活后，应用图标会换成戴飞行员墨镜的版本。"], "en": ["Searching external drives is now free: drives are indexed when you plug them in and kept up to date, and you can turn off any drive in Settings.", "Pro keeps drives searchable after you unplug them, along with image and document content search.", "When Pro is active, the app icon switches to a version wearing aviators."]});
  });
  it('includes the exact bilingual 1.5.0 document-search announcement', () => {
    expect(releases.find(release => release.version === '1.5.0')?.notes).toEqual({
      zh: ['Oil Find Pro 新增文档内容搜索：PDF、Word、PowerPoint、Excel、Pages、Markdown 和纯文本里的文字都能搜到，扫描版 PDF 会识别前 10 页。全部在本机处理。'],
      en: ['Oil Find Pro now searches inside documents: PDF, Word, PowerPoint, Excel, Pages, Markdown and plain text, plus the first 10 pages of scanned PDFs. Everything is processed on your Mac.'],
    });
  });

  it('publishes the exact bilingual 1.3.0 open source announcement', () => {
    expect(releases.find(release => release.version === '1.3.0')).toEqual({
      version: '1.3.0',
      date: '2026-10-06',
      notes: {
        zh: ['Oil Find 开源了，完全免费，不再需要授权。代码在 GitHub：github.com/oil-oil/oil-find。'],
        en: ['Oil Find is now open source and completely free. No license needed. The code is at github.com/oil-oil/oil-find.'],
      },
    });
    expect(changelogTitle).toEqual({ zh: '更新日志', en: 'Changelog' });
  });

  it.each(['latest-v2.json', 'latest.json'])('keeps %s aligned with its published release, including before packaging the next release', feed => {
    const manifest = JSON.parse(readFileSync(new URL(`../public/updates/${feed}`, import.meta.url), 'utf8'));
    const published = releases.find(release => release.version === manifest.version)!;
    expect(manifest).toMatchObject({
      version: published.version,
      published: published.date,
      url: `https://find.oiloil.org/downloads/Oil-Find-${published.version}.zip`,
      notes: published.notes,
    });
    expect(manifest.size).toBeGreaterThan(0);
    expect(manifest.sha256).toMatch(/^[a-f0-9]{64}$/);
  });

  it('keeps both update feeds uncached', async () => {
    const configURL = new URL('../next.config.mjs', import.meta.url).href;
    const { default: config } = await import(configURL);
    const rules = await config.headers();
    for (const feed of ['latest-v2.json', 'latest.json']) {
      expect(rules).toContainEqual({
        source: `/updates/${feed}`,
        headers: [{ key: 'Cache-Control', value: 'no-cache' }],
      });
    }
  });

  it.skipIf(process.platform !== 'darwin')('generates a matching manifest and refuses a release without notes', () => {
    const directory = mkdtempSync(join(tmpdir(), 'oilfind-manifest-'));
    try {
      const plist = join(directory, 'Info.plist'), archive = join(directory, 'test.zip'), output = join(directory, 'latest.json');
      const script = new URL('../../scripts/generate-update-manifest.mjs', import.meta.url).pathname;
      const info = (version: string) => `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>5</string><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>`;
      writeFileSync(plist, info(releases[0].version)); writeFileSync(archive, 'test archive bytes');
      execFileSync(process.execPath, ['--experimental-strip-types', script, plist, archive, output], { stdio: 'pipe' });
      const manifest = JSON.parse(readFileSync(output, 'utf8'));
      expect(manifest).toEqual({ version: releases[0].version, build: 5, url: `https://find.oiloil.org/downloads/Oil-Find-${releases[0].version}.zip`, size: 18,
        sha256: createHash('sha256').update('test archive bytes').digest('hex'), minimumSystemVersion: '14.0', published: releases[0].date, notes: releases[0].notes });
      rmSync(output); writeFileSync(plist, info('99.0.0'));
      expect(() => execFileSync(process.execPath, ['--experimental-strip-types', script, plist, archive, output], { stdio: 'pipe' })).toThrow(/Release notes for 99.0.0 are missing/);
      expect(existsSync(output)).toBe(false);
      expect(existsSync(output + '.tmp')).toBe(false);
    } finally { rmSync(directory, { recursive: true, force: true }); }
  });
});
