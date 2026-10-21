from playwright.sync_api import sync_playwright
import json
import os
import sys
import time
from pathlib import Path
def wait_images(page, selector):
 deadline=time.monotonic()+30
 while time.monotonic()<deadline:
  if page.locator(selector).evaluate_all("images => images.length > 0 && images.every(i => i.complete && i.naturalWidth > 0)"): return
  time.sleep(.1)
 raise AssertionError("Images did not load: "+selector)
BASE=sys.argv[1].rstrip("/") if len(sys.argv)>1 else "http://127.0.0.1:18080"
with sync_playwright() as p:
 browser=p.chromium.launch(executable_path=os.environ.get("BROWSER_EXECUTABLE"))
 page=browser.new_page(viewport={'width':1440,'height':1050},device_scale_factor=1)
 if len(sys.argv)>2:
  web=Path(sys.argv[2])
  assets=[('index.html','text/html'),('app.js','text/javascript'),('style.css','text/css')]
  if (web/'catalogue.json').exists():assets.append(('catalogue.json','application/json'))
  for name, mime in assets:
   target=BASE+'/' if name=='index.html' else BASE+'/'+name
   page.route(lambda url,t=target:url.split("?")[0]==t,lambda route,request,n=name,m=mime:route.fulfill(response=route.fetch(),body=(web/n).read_text(),content_type=m))
 errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
 page.goto(BASE+'/');page.wait_for_selector('.card')
 assert page.locator('.card').count()==60
 wait_images(page, ".card:nth-child(-n+8) img")
 assert page.locator('#filters').bounding_box()['width']==208
 assert page.locator('.app-header').bounding_box()['height']==64
 assert page.locator('.intro').count()==0
 assert page.locator('.thumb-box').first.bounding_box()['height']==150
 if len(sys.argv)>3: page.screenshot(path=str(Path(sys.argv[3])/'gallery.png'))
 search=page.locator('#search')
 search.fill('4k_')
 page.wait_for_selector('#search-suggestions li')
 assert search.get_attribute('aria-expanded')=='true'
 chosen=page.locator('#search-suggestions li span').first.inner_text()
 assert chosen.startswith('4k_')
 search.press('ArrowDown');search.press('Enter')
 assert search.input_value()==chosen+' '
 assert not page.locator('#search-suggestions').is_visible()
 page.locator('#collection').click()
 search.fill('metalheart -4k_')
 page.locator('#search-suggestions li').first.click()
 assert search.input_value()=='metalheart -'+chosen+' '
 search.fill('"4k_');assert not page.locator('#search-suggestions').is_visible()
 search.fill('4k_');search.press('Escape');assert not page.locator('#search-suggestions').is_visible()
 search.fill('4k_');page.locator('#page-title').click();assert not page.locator('#search-suggestions').is_visible()
 page.locator('#collection').click()
 page.locator('.card-open').first.click();assert page.locator('#detail').is_visible()
 wait_images(page, "#full-image")
 assert page.locator('#filters').is_visible() and not page.locator('#gallery').is_visible()
 if len(sys.argv)>3: page.screenshot(path=str(Path(sys.argv[3])/'detail.png'))
 page.locator('#favorite-detail').click();assert page.locator('#favorite-detail').get_attribute('aria-pressed')=='true'
 catalogue=page.request.get(BASE+'/catalogue.json').json()['items']
 held=[]
 delayed_url=BASE+'/'+catalogue[1]['file']
 page.route(delayed_url,lambda route:held.append(route))
 old_src=page.locator('#full-image').get_attribute('src')
 page.keyboard.press('ArrowRight');assert page.locator('#detail-position').inner_text().startswith('2 /')
 assert not page.locator('#full-image').is_visible()
 assert page.locator('#full-image').get_attribute('src')!=old_src
 assert page.locator('#image-status').is_visible()
 deadline=time.monotonic()+10
 while not held and time.monotonic()<deadline:page.wait_for_timeout(20)
 assert held
 page.keyboard.press('ArrowRight');wait_images(page,'#full-image')
 current_src=page.locator('#full-image').get_attribute('src')
 held[0].fulfill(response=held[0].fetch())
 page.wait_for_timeout(100)
 assert page.locator('#full-image').get_attribute('src')==current_src
 assert page.locator('#full-image').is_visible() and not page.locator('#image-status').is_visible()
 page.unroute(delayed_url)
 page.keyboard.press('Escape');assert not page.locator('#detail').is_visible()
 page.locator('#favorites').click();assert page.locator('.card').count()==1
 page.reload();page.wait_for_selector('.card');assert page.locator('.card').count()==1
 page.locator('#collection').click();page.locator('#search').fill('nonexistent_test_word');page.locator('#search-form button').click();assert page.locator('#empty').is_visible()
 page.locator('#collection').click();page.locator('#tag-search').fill('sky');page.locator('#tag-list button').first.click();assert page.locator('#selected-tags button').count()==1
 page.locator('#collection').click()
 page.locator('#tag-search').fill('metalheart');page.locator('#tag-list button').first.click()
 expected=sum('metalheart' in item['tags'] for item in catalogue)
 assert expected>0
 for suffix in ['', ' -l', ' -llo', ' -llowe', ' -METALHEART']:
  page.locator('#search').fill('metalheart'+suffix);page.locator('#search-form button').click()
  count=0 if suffix==' -METALHEART' else expected
  assert page.locator('#results').inner_text()==f"Found: {count:,} of {len(catalogue):,}"
 page.locator('#collection').click()
 page.locator('#gallery').evaluate('el => el.scrollTop = el.scrollHeight')
 deadline=time.monotonic()+15
 while page.locator('.card').count()<=60 and time.monotonic()<deadline:time.sleep(.1)
 assert page.locator('.card').count()>60
 page.locator('.card-open').nth(59).click()
 page.go_back();assert not page.locator('#detail').is_visible()
 assert page.locator('#gallery').evaluate('el => el.scrollTop')>0
 page.locator('#collection').click();page.set_viewport_size({'width':390,'height':844});page.evaluate('scrollTo(0,0)')
 assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
 wait_images(page, ".card:nth-child(-n+4) img")
 assert page.locator('.card img').first.evaluate('i => Math.abs(i.width / i.height - i.naturalWidth / i.naturalHeight) < .03')
 search.fill('4k_');page.wait_for_selector('#search-suggestions li')
 box=page.locator('#search-suggestions').bounding_box()
 assert box['x']>=0 and box['x']+box['width']<=390
 page.locator('#search-suggestions li').first.click()
 assert search.input_value()==chosen+' '
 page.locator('#reset').click()
 if len(sys.argv)>3: page.screenshot(path=str(Path(sys.argv[3])/'mobile.png'))
 page.locator('#filters-toggle').click();assert page.locator('#filters').is_visible()
 page.locator('#drawer-shade').click(position={'x':300,'y':200});assert not page.locator('#filters').is_visible()
 for path in ['collection.db','device.json','.env','staging/','../etc/passwd']:
  assert page.request.get(BASE+'/'+path).status==404,path
 response=page.request.get(BASE+'/')
 assert 'frame-ancestors' in response.headers.get('content-security-policy','')
 assert page.locator('link[rel=icon]').get_attribute('href')=='/favicon.svg'
 icon=page.request.get(BASE+'/favicon.svg')
 assert icon.status==200 and 'image/svg+xml' in icon.headers.get('content-type','')
 assert '<svg' in icon.text()
 assert not errors,errors
 print(json.dumps({'browser':'Chromium','desktop':True,'mobile':True,'search':True,'tags':True,'favorites_persist':True,'keyboard':True,'desktop_layout':True,'infinite_scroll':True,'browser_back':True,'delayed_image_race':True,'private_paths_404':True,'page_errors':errors}))
 browser.close()
