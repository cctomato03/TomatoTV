#!/usr/bin/env node
/**
 * 文档预览页集成测试（本地，需要 Chrome/Edge）。
 *
 * 验证 rawfile/viewer 下的 PDF / DOCX / XLSX / PPTX 四个离线渲染页面：
 *  1. 起一个本地静态服务，把 viewer 目录当站点根，并把 /doc、/worker 映射到测试样本；
 *  2. 用 puppeteer-core 打开每个页面（注入 window.TOMATO_DOC_URL 指向同源地址）；
 *  3. 断言页面确实渲染出了内容（canvas / 表格单元格 / docx section / slide 容器）。
 *
 * 用法：
 *   npm i -D puppeteer-core        # 仅本地/可选 CI 使用
 *   node scripts/test/run-viewer.mjs [--browser "C:\\...\\chrome.exe"]
 */
import { createServer } from 'node:http';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const viewerDir = join(root, 'entry/src/main/resources/rawfile/viewer');
const fixturesDir = join(root, 'test/fixtures');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8'
};

const FIXTURES = {
  pdf: 'sample.pdf',
  docx: 'sample.docx',
  sheet: 'sample.xlsx',
  pptx: 'sample.pptx'
};

function findBrowser() {
  const fromArg = process.argv.indexOf('--browser');
  if (fromArg > 0 && process.argv[fromArg + 1]) {
    return process.argv[fromArg + 1];
  }
  if (process.env.CHROME_PATH) {
    return process.env.CHROME_PATH;
  }
  const candidates = [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser'
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return '';
}

function startServer(currentFixture) {
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/doc') {
      const name = FIXTURES[currentFixture.value];
      const data = readFileSync(join(fixturesDir, name));
      res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': data.length });
      res.end(data);
      return;
    }
    if (url.pathname === '/worker') {
      const data = readFileSync(join(viewerDir, 'pdf/pdf.worker.min.js'));
      res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8', 'Content-Length': data.length });
      res.end(data);
      return;
    }
    const filePath = join(viewerDir, url.pathname);
    if (!filePath.startsWith(viewerDir) || !existsSync(filePath)) {
      res.writeHead(404);
      res.end('not found');
      return;
    }
    const data = readFileSync(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[extname(filePath)] || 'application/octet-stream',
      'Content-Length': data.length
    });
    res.end(data);
  });
  return new Promise((resolvePort) => {
    server.listen(0, '127.0.0.1', () => resolvePort({ server, port: server.address().port }));
  });
}

const CHECKS = {
  pdf: async (page) => {
    const canvases = await page.$$eval('canvas', (nodes) =>
      nodes.filter((node) => node.width > 0 && node.height > 0).length);
    return canvases >= 2 ? '' : `canvas 数量不足: ${canvases}`;
  },
  docx: async (page) => {
    const result = await page.evaluate(() => {
      const root = document.getElementById('root');
      const text = root ? root.innerText : '';
      return {
        sections: root ? root.querySelectorAll('section').length : 0,
        hasTitle: text.includes('TomatoTV') || text.includes('文档预览测试'),
        tableCells: root ? root.querySelectorAll('table td').length : 0
      };
    });
    if (result.sections < 1) {
      return `未渲染出 section: ${JSON.stringify(result)}`;
    }
    if (!result.hasTitle) {
      return `缺少标题文本: ${JSON.stringify(result)}`;
    }
    if (result.tableCells < 6) {
      return `表格单元格不足: ${result.tableCells}`;
    }
    return '';
  },
  sheet: async (page) => {
    const result = await page.evaluate(() => ({
      rows: document.querySelectorAll('#sheet table tr').length,
      cells: document.querySelectorAll('#sheet table td').length,
      tabs: document.querySelectorAll('#tabs .tab').length
    }));
    if (result.tabs < 2) {
      return `工作表标签数量不足: ${JSON.stringify(result)}`;
    }
    if (result.cells < 12) {
      return `表格单元格不足: ${JSON.stringify(result)}`;
    }
    return '';
  },
  pptx: async (page) => {
    const result = await page.evaluate(() => ({
      slides: document.querySelectorAll('.pptx-preview-slide-wrapper, .pptx-preview-slide').length,
      text: document.getElementById('host') ? document.getElementById('host').innerText.length : 0
    }));
    if (result.slides < 2) {
      return `幻灯片数量不足: ${JSON.stringify(result)}`;
    }
    return '';
  }
};

const browserPath = findBrowser();
if (browserPath === '') {
  console.error('❌ 未找到 Chrome/Edge，可用 --browser <path> 或 CHROME_PATH 指定');
  process.exit(1);
}
console.log(`使用浏览器: ${browserPath}`);

const currentFixture = { value: 'pdf' };
const { server, port } = await startServer(currentFixture);
const browser = await puppeteer.launch({
  executablePath: browserPath,
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--font-render-hinting=none']
});

const failures = [];
try {
  for (const kind of Object.keys(FIXTURES)) {
    currentFixture.value = kind;
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(String(error)));
    page.on('console', (message) => {
      if (message.type() === 'error') {
        pageErrors.push(message.text());
      }
    });
    await page.setViewport({ width: 900, height: 1200 });
    await page.evaluateOnNewDocument(() => {
      window.TOMATO_DOC_URL = '/doc';
      window.TOMATO_WORKER_URL = '/worker';
    });
    await page.goto(`http://127.0.0.1:${port}/${kind}/index.html`, { waitUntil: 'load', timeout: 30000 });
    let problem = '';
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 600));
      problem = await CHECKS[kind](page);
      if (problem === '') {
        break;
      }
      const statusText = await page.evaluate(() => {
        const node = document.getElementById('status');
        return node && node.style.display !== 'none' ? node.innerText : '';
      });
      if (statusText && statusText.includes('无法')) {
        problem = problem + ' | 页面提示: ' + statusText;
        break;
      }
    }
    if (problem === '') {
      console.log(`✅ ${kind} 渲染通过`);
    } else {
      failures.push(`${kind}: ${problem}`);
      console.error(`❌ ${kind}: ${problem}`);
      if (pageErrors.length > 0) {
        console.error('   页面错误: ' + pageErrors.slice(0, 5).join(' | '));
      }
    }
    await page.close();
  }
} finally {
  await browser.close();
  server.close();
}

if (failures.length > 0) {
  console.error(`\n❌ ${failures.length} 个预览页未通过`);
  process.exitCode = 1;
} else {
  console.log('\n✅ 四个文档预览页渲染全部通过');
}
