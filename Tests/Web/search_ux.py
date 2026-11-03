"""Search interaction regressions. Optional second argument overrides UI assets."""
import json
import os
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

base = sys.argv[1].rstrip('/')
web = Path(sys.argv[2]) if len(sys.argv) > 2 else None
engines = os.environ.get('SEARCH_BROWSERS', 'chromium').split(',')
with sync_playwright() as p:
    for engine in engines:
        launch = {}
        if engine == 'chromium' and os.environ.get('BROWSER_EXECUTABLE'):
            launch['executable_path'] = os.environ['BROWSER_EXECUTABLE']
        browser = getattr(p, engine).launch(**launch)
        for mobile in (False, True):
            context = browser.new_context(
                viewport={'width': 390 if mobile else 1440, 'height': 844},
                is_mobile=mobile, has_touch=mobile,
            )
            if web:
                for name, mime in [('index.html', 'text/html'), ('app.js', 'text/javascript'), ('style.css', 'text/css')]:
                    target = base + '/' if name == 'index.html' else base + '/' + name
                    context.route(target, lambda route, request, n=name, m=mime: route.fulfill(
                        response=route.fetch(), body=(web/n).read_text(), content_type=m))
            page = context.new_page()
            errors = []
            page.on('pageerror', lambda e: errors.append(str(e)))
            page.goto(base + '/')
            page.wait_for_selector('.card')
            initial_results = page.locator('#results').inner_text()
            search = page.locator('#search')
            popup = page.locator('#search-suggestions')
            rows = popup.locator('li')
            search.fill('m')
            expect(popup).to_be_visible()
            tags = rows.locator('span').all_text_contents()
            assert len(tags) > 1
            search.press('Tab')
            assert search.get_attribute('aria-activedescendant') == 'search-suggestion-0'
            assert search.input_value() == 'm'
            search.press('Tab')
            assert search.get_attribute('aria-activedescendant') == 'search-suggestion-1'
            search.press('Shift+Tab')
            search.press('Enter')
            assert search.input_value() == tags[0] + ' '
            expect(popup).to_be_hidden()
            expect(search).to_be_focused()
            # All suggestions are reachable, with a forward exit to Search.
            search.fill('m')
            for i in range(rows.count()):
                search.press('Tab')
                assert search.get_attribute('aria-activedescendant') == f'search-suggestion-{i}'
            search.press('Tab')
            expect(page.locator('#search-form > button')).to_be_focused()
            expect(popup).to_be_hidden()
            # Reverse traversal returns to the input, then leaves normally.
            search.fill('m')
            search.press('Tab'); search.press('Shift+Tab')
            assert search.get_attribute('aria-activedescendant') is None
            expect(search).to_be_focused()
            search.press('Shift+Tab')
            expect(search).not_to_be_focused()
            expect(popup).to_be_hidden()
            search.fill('metal')
            search.press('ArrowDown'); search.press('Escape')
            expect(popup).to_be_hidden()
            assert search.input_value() == 'metal'
            search.fill('metal')
            search.press('ArrowLeft')
            expect(popup).to_be_hidden()
            search.press('End')
            expect(popup).to_be_visible()
            search.press('ControlOrMeta+a')
            expect(popup).to_be_hidden()
            search.fill('metal')
            search.dispatch_event('compositionstart')
            expect(popup).to_be_hidden()
            search.dispatch_event('compositionend')
            expect(popup).to_be_visible()
            # Reproduce blur-before-click explicitly, also when relatedTarget is null.
            row = rows.filter(has_text='metalheart').first
            row.dispatch_event('pointerdown', {'pointerId': 42, 'pointerType': 'touch'})
            search.evaluate('el => el.blur()')
            expect(popup).to_be_visible()
            row.dispatch_event('pointerup', {'pointerId': 42, 'pointerType': 'touch'})
            row.dispatch_event('click')
            assert search.input_value() == 'metalheart '
            expect(popup).to_be_hidden()
            # Real pointer/touch activation, including a negative token.
            search.fill('aero -metal')
            row = rows.filter(has_text='metalheart').first
            row.tap() if mobile else row.click()
            assert search.input_value() == 'aero -metalheart '
            expect(popup).to_be_hidden()
            search.fill('metal')
            page.touchscreen.tap(2, 500) if mobile else page.locator('#page-title').click()
            expect(popup).to_be_hidden()
            search.fill('metal')
            search.press('Enter')
            expect(popup).to_be_hidden()
            assert search.input_value() == 'metal'
            search.fill('metal')
            search.fill('')
            search.dispatch_event('search')
            expect(popup).to_be_hidden()
            expect(page.locator('#results')).to_have_text(initial_results)
            if mobile:
                if engine == 'chromium':
                    # A real touch pan must scroll rather than select or dismiss.
                    search.fill('m')
                    box = popup.bounding_box()
                    cdp = context.new_cdp_session(page)
                    x, y = box['x'] + box['width']/2, box['y'] + box['height'] - 25
                    cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]})
                    for delta in range(20, 181, 20):
                        cdp.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': x, 'y': y-delta}]})
                        page.wait_for_timeout(20)
                    cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
                    expect(popup).to_be_visible()
                    assert popup.evaluate('el => el.scrollTop') > 0
                    assert search.input_value() == 'm'
                    cdp.detach()
                for width in (320, 390, 1024):
                    page.set_viewport_size({'width': width, 'height': 844})
                    assert search.evaluate('el => parseFloat(getComputedStyle(el).fontSize)') >= 16
                    assert page.locator('#tag-search').evaluate('el => parseFloat(getComputedStyle(el).fontSize)') >= 16
                    search.fill('m')
                    assert rows.first.bounding_box()['height'] >= 44
                    box = popup.bounding_box()
                    assert box['x'] >= 0 and box['x'] + box['width'] <= width
                    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
                # A scroll/cancel gesture must not select a suggestion.
                row = rows.first
                row.dispatch_event('pointerdown', {'pointerId': 43, 'pointerType': 'touch'})
                assert search.input_value() == 'm'
                row.dispatch_event('pointercancel', {'pointerId': 43, 'pointerType': 'touch'})
                expect(popup).to_be_visible()
                assert search.input_value() == 'm'
                assert 'user-scalable=no' not in page.locator('meta[name=viewport]').get_attribute('content')
            assert not errors, errors
            print(json.dumps({'engine': engine, 'mobile': mobile, 'search_ux': 'PASS', 'errors': errors}), flush=True)
            context.close()
        browser.close()
