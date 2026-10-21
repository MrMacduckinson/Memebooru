"""Check actual rendered spacing at mobile, tablet and desktop widths."""
import json
import os
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

base = sys.argv[1].rstrip('/')
css = Path(sys.argv[2]) if len(sys.argv) > 2 else None
shots = Path(sys.argv[3]) if len(sys.argv) > 3 else None
widths = [320, 360, 361, 390, 760, 761, 1024, 1107, 1108, 1440, 1920]
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get('BROWSER_EXECUTABLE'))
    page = browser.new_page(viewport={'width': 1440, 'height': 1000})
    if css:
        page.route(base + '/style.css', lambda route: route.fulfill(
            response=route.fetch(), body=css.read_text(), content_type='text/css'))
    page.goto(base + '/')
    page.wait_for_selector('.card')
    def check(width, detail=False):
        page.set_viewport_size({'width': width, 'height': 1000})
        metrics = page.evaluate('''() => {
          const rect = s => document.querySelector(s).getBoundingClientRect();
          const button = document.querySelector('#search-form button');
          const range = document.createRange(); range.selectNodeContents(button);
          const text = range.getBoundingClientRect(), b = button.getBoundingClientRect();
          const header = rect('.app-header'), form = rect('#search-form'), brand = rect('.brand');
          const region = document.querySelector('#detail').hidden ? '#gallery' : '#detail';
          const style = getComputedStyle(document.querySelector(region));
          const selectors = ['.brand', '#search-form', '.page-header', '#grid', '.breadcrumb',
            '.detail-columns', '.detail-main', '.detail-side', '.post-heading', '#detail-tags',
            '.detail-nav', '#detail-prev', '#detail-next', '#favorite-detail', '#detail-meta'];
          const overflow = selectors.filter(s => {
            const e = document.querySelector(s); if (!e.getClientRects().length) return false;
            const r=e.getBoundingClientRect(); return r.left < -1 || r.right > innerWidth + 1;
          });
          return {left: text.left-b.left, right: b.right-text.right,
            formLeft: form.left, formRight: innerWidth-form.right,
            headerTop: form.top-header.top, headerBottom: header.bottom-form.bottom,
            brandGap: form.left-brand.right, brandBottom: brand.bottom, formTop: form.top,
            paddingLeft: parseFloat(style.paddingLeft), paddingRight: parseFloat(style.paddingRight),
            overflow, documentOverflow: document.documentElement.scrollWidth > innerWidth,
            regionOverflow: document.querySelector(region).scrollWidth > document.querySelector(region).clientWidth};
        }''')
        assert not metrics['overflow'], (width, detail, metrics)
        assert not metrics['documentOverflow'] and not metrics['regionOverflow'], (width, detail, metrics)
        assert min(metrics['left'], metrics['right']) >= 11.5, (width, metrics)
        assert abs(metrics['left'] - metrics['right']) <= 1.5, (width, metrics)
        assert min(metrics['headerTop'], metrics['headerBottom']) >= 8, (width, metrics)
        assert metrics['paddingLeft'] == metrics['paddingRight'] == (16 if width <= 760 else 24)
        if width <= 760:
            assert metrics['formLeft'] == metrics['formRight'] == 12
            assert metrics['formTop'] - metrics['brandBottom'] >= 8
        else:
            assert metrics['brandGap'] >= 24 and metrics['formRight'] >= 24
        if shots and width in [390, 1440]:
            page.screenshot(path=str(shots / f"{'detail' if detail else 'gallery'}-{width}.png"))
        return metrics
    gallery = {w: check(w) for w in widths}
    page.set_viewport_size({'width':1440,'height':1000})
    page.locator('.card-open').first.click()
    page.wait_for_function("() => document.querySelector('#full-image').naturalWidth > 0")
    detail = {w: check(w, True) for w in widths}
    print(json.dumps({'widths': widths, 'gallery': gallery, 'detail': detail}))
    browser.close()
