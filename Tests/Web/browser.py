from playwright.sync_api import sync_playwright
import json
import sys
import time
def wait_images(page, selector):
 deadline=time.monotonic()+30
 while time.monotonic()<deadline:
  if page.locator(selector).evaluate_all("images => images.length > 0 && images.every(i => i.complete && i.naturalWidth > 0)"): return
  time.sleep(.1)
 raise AssertionError("Images did not load: "+selector)
BASE=sys.argv[1].rstrip("/") if len(sys.argv)>1 else "http://127.0.0.1:18080"
with sync_playwright() as p:
 browser=p.chromium.launch()
 page=browser.new_page(viewport={'width':1440,'height':1050},device_scale_factor=1)
 errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
 page.goto(BASE+'/');page.wait_for_selector('.card')
 assert page.locator('.card').count()==60
 wait_images(page, ".card:nth-child(-n+8) img")
 page.locator('.card-open').first.click();assert page.locator('#detail').is_visible()
 wait_images(page, "#full-image")
 page.locator('#favorite-detail').click();assert page.locator('#favorite-detail').get_attribute('aria-pressed')=='true'
 page.keyboard.press('ArrowRight');assert page.locator('#detail-position').inner_text().startswith('2 /')
 page.keyboard.press('Escape');assert not page.locator('#detail').is_visible()
 page.locator('#favorites').click();assert page.locator('.card').count()==1
 page.reload();page.wait_for_selector('.card');assert page.locator('.card').count()==1
 page.locator('#reset').click();page.locator('#search').fill('nonexistent_test_word');page.locator('#search-form button').click();assert page.locator('#empty').is_visible()
 page.locator('#reset').click();page.locator('#tag-search').fill('небо');page.locator('#tag-list button').first.click();assert page.locator('#selected-tags button').count()==1
 page.locator('#reset').click();page.set_viewport_size({'width':390,'height':844});page.evaluate('scrollTo(0,0)')
 assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
 page.locator('#filters-toggle').click();assert page.locator('#filters').is_visible()
 for path in ['collection.db','device.json','.env','staging/','../etc/passwd']:
  assert page.request.get(BASE+'/'+path).status==404,path
 response=page.request.get(BASE+'/')
 assert 'frame-ancestors' in response.headers.get('content-security-policy','')
 assert not errors,errors
 print(json.dumps({'browser':'Chromium','desktop':True,'mobile':True,'search':True,'tags':True,'favorites_persist':True,'keyboard':True,'private_paths_404':True,'page_errors':errors}))
 browser.close()
