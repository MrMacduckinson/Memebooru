import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('download',Path(__file__).resolve().parents[2]/'scripts/wallpapers/download.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class CatalogueTests(unittest.TestCase):
    def test_only_gallery_originals_and_same_site_pages(self):
        p=m.Catalogue(m.START)
        p.feed('<a href="/wallpapers/next">Next</a><a href="/images/wallpapers/a/1.jpg" download alt="One"></a><a href="/images/wallpapers/a/thumbnails/1.jpg"></a><a href="https://evil.test/wallpapers/no">No</a><a href="/images/logo.png">Logo</a>')
        self.assertEqual(p.pages,{m.BASE+'/wallpapers/next'})
        self.assertEqual(len(p.images),1)
        self.assertEqual(next(iter(p.images.values()))['title'],'One')
    def test_cached_catalogue_cannot_write_outside_destination(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            for item in [
                {'url':m.BASE+'/images/wallpapers/a.jpg', 'file':'../../secret.jpg'},
                {'url':'https://evil.test/images/wallpapers/a.jpg', 'file':'originals/a.jpg'}
            ]:
                with self.assertRaises(ValueError): m.validate_item(item,Path(d))
if __name__=='__main__' :unittest.main()
