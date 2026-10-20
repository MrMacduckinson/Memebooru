#!/usr/bin/env python3
"""Download the wallpaper catalogue, keeping provenance and resumable local files."""
import argparse
import concurrent.futures
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import time
from urllib.parse import urljoin, urlsplit, unquote
from urllib.request import Request, urlopen

BASE = 'https://frutigeraeroarchive.org'
START = BASE + '/wallpapers'
UA = 'Memebooru archive importer (personal collection)'
IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif', '.tif', '.tiff'}

class Catalogue(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.page, self.pages, self.images = page, set(), {}
        self.title_parts, self.in_title = [], False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'title': self.in_title = True
        if tag != 'a' or 'href' not in a: return
        url = urljoin(self.page, a['href']).split('#')[0]
        u = urlsplit(url)
        if u.netloc != urlsplit(BASE).netloc or u.scheme != 'https': return
        if u.path == '/wallpapers' or u.path.startswith('/wallpapers/'):
            self.pages.add(url)
        if '/images/wallpapers/' in u.path and '/thumbnails/' not in u.path and Path(u.path).suffix.lower() in IMAGE_EXTENSIONS:
            self.images[url] = {'url': url, 'sourcePage': self.page,
                                'title': a.get('alt') or (a.get('title') if a.get('title') != 'Download original file' else None) or Path(unquote(u.path)).stem}
    def handle_endtag(self, tag):
        if tag == 'title': self.in_title = False
    def handle_data(self, text):
        if self.in_title: self.title_parts.append(text)

def fetch(url):
    for attempt in range(4):
        try:
            with urlopen(Request(url, headers={'User-Agent': UA}), timeout=60) as response:
                if urlsplit(response.url).netloc != urlsplit(BASE).netloc: raise ValueError('Unexpected redirect')
                started = time.monotonic()
                chunks = []
                while chunk := response.read(65536):
                    chunks.append(chunk)
                    if time.monotonic() - started > 120:
                        raise TimeoutError('Download exceeded 120 seconds; will retry')
                content = b''.join(chunks)
                expected = response.headers.get('Content-Length')
                if expected is not None and len(content) != int(expected):
                    raise IOError('Incomplete HTTP response')
                return content
        except Exception:
            if attempt == 3: raise
            time.sleep(2 ** attempt)

def write_json(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    tmp.replace(path)

def validate_item(item, root):
    url = urlsplit(item['url'])
    expected = 'originals/' + hashlib.sha256(item['url'].encode()).hexdigest()[:20] + Path(url.path).suffix.lower()
    dest = (root / item['file']).resolve()
    if (url.scheme != 'https' or url.netloc != urlsplit(BASE).netloc
            or '/images/wallpapers/' not in url.path
            or Path(url.path).suffix.lower() not in IMAGE_EXTENSIONS
            or item['file'] != expected or not dest.is_relative_to(root.resolve())):
        raise ValueError('Invalid or escaping catalogue entry')
    return dest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('destination', type=Path)
    p.add_argument('--workers', type=int, default=3)
    p.add_argument('--catalogue-only', action='store_true')
    p.add_argument('--manifest', type=Path, help='Use the published, tagged catalogue and verify its original checksums')
    args = p.parse_args()
    if not 1 <= args.workers <= 8: p.error('workers must be 1–8')
    root = args.destination.resolve(); root.mkdir(parents=True, exist_ok=True)
    catalogue = root / 'catalogue.json'
    if args.manifest:
        data = json.loads(args.manifest.read_text())
    elif catalogue.exists():
        data = json.loads(catalogue.read_text())
    else:
        pages, pending, images = {}, {START}, {}
        while pending:
            page = sorted(pending)[0]; pending.remove(page)
            if page in pages: continue
            parsed = Catalogue(page); parsed.feed(fetch(page).decode('utf-8'))
            pages[page] = {'title': ''.join(parsed.title_parts).strip(), 'images': len(parsed.images)}
            for url, item in parsed.images.items():
                if url not in images:
                    item['category'] = urlsplit(url).path.split('/wallpapers/')[1].split('/')[0]
                    item['file'] = 'originals/' + hashlib.sha256(url.encode()).hexdigest()[:20] + Path(urlsplit(url).path).suffix.lower()
                    images[url] = item
            pending |= parsed.pages - pages.keys()
            print(f'Catalogue: {len(pages)} pages, {len(images)} images', flush=True)
            time.sleep(.15)
        data = {'source': START, 'pages': pages, 'items': list(images.values())}
        write_json(catalogue, data)
    for item in data['items']: validate_item(item, root)
    if args.catalogue_only: return
    (root / 'originals').mkdir(exist_ok=True)
    def download(item):
        dest = validate_item(item, root)
        try:
            if not dest.exists():
                content = fetch(item['url'])
                from PIL import Image
                import io
                with Image.open(io.BytesIO(content)) as im: im.verify()
                tmp = dest.with_suffix(dest.suffix + '.part'); tmp.write_bytes(content); tmp.replace(dest)
            from PIL import Image
            with Image.open(dest) as im:
                width, height = im.size
            sha = hashlib.sha256(dest.read_bytes()).hexdigest()
            if item.get('sha256') and sha != item['sha256']:
                raise ValueError('Original differs from the published SHA-256')
            return {**item, 'sha256': sha,
                    'bytes': dest.stat().st_size, 'width': width, 'height': height}
        except Exception as exc:
            return {**item, 'error': str(exc)}
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(download, item) for item in data['items']]
        order = {item['url']: i for i, item in enumerate(data['items'])}
        for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
            results.append(future.result())
            if i % 50 == 0 or i == len(data['items']):
                write_json(root / 'downloaded.json', {**data, 'items': sorted(results, key=lambda item: order[item['url']])})
                print(f'Downloaded {i}/{len(data["items"])}; errors {sum("error" in x for x in results)}', flush=True)
    if any('error' in x for x in results): raise SystemExit('Incomplete download; rerun to retry missing files')
    if all(item.get('tags') for item in results):
        write_json(root / 'tagged.json', {**data, 'items': sorted(results, key=lambda item: order[item['url']])})

if __name__ == '__main__': main()
