import sys
from pathlib import Path
import tempfile
import unittest
from PIL import Image, ImageFile
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/wallpapers'))
from tag import load_image, measured_tags, reviewed_tags

class TaggingTests(unittest.TestCase):
    def test_reviews_are_scoped_to_url_or_original_asadal_group(self):
        item = {'url': 'https://example.test/image.jpg', 'category': 'other'}
        reviews = {'image.jpg': ['legacy'], item['url']: ['reviewed']}
        self.assertEqual(reviewed_tags(item, reviews), ['reviewed'])
        del reviews[item['url']]
        self.assertIsNone(reviewed_tags(item, reviews))
        item['category'] = 'asadal_stock'
        self.assertEqual(reviewed_tags(item, reviews), ['legacy'])

    def test_incomplete_original_is_preserved_and_warning_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'original.jpg'
            Image.new('RGB', (64, 64), 'blue').save(path)
            original = path.read_bytes()[:-2]
            path.write_bytes(original)
            previous = ImageFile.LOAD_TRUNCATED_IMAGES
            image, warning = load_image(path)
            self.assertEqual(image.size, (64, 64))
            self.assertIsNotNone(warning)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(ImageFile.LOAD_TRUNCATED_IMAGES, previous)
    def test_measured_tags_describe_pixels_and_dimensions(self):
        tags = measured_tags(Image.new('RGB', (16, 9), 'blue'), 1920, 1080)
        self.assertTrue({'синий', 'full_hd', 'горизонтальный', 'формат_16_9'} <= set(tags))

if __name__ == '__main__': unittest.main()
