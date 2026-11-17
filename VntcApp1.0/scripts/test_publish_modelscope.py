import tempfile
import unittest
from pathlib import Path
from publish_modelscope import manifest_for, download_url, publish
from unittest.mock import patch, Mock

class ManifestTests(unittest.TestCase):
    def test_manifest_has_fixed_repository_sha_size_and_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'VNT_App_4.8.42_Windows_Setup.exe').write_bytes(b'real artifact fixture')
            (root / 'latest.json').write_text('{}')
            result = manifest_for(root, '4.8.42', 'source-sha', 'notes')
            self.assertEqual(result['source_commit'], 'source-sha')
            self.assertEqual(len(result['assets']), 1)
            asset = result['assets'][0]
            self.assertEqual(asset['size'], 21)
            self.assertEqual(len(asset['sha256']), 64)
            self.assertEqual(asset['browser_download_url'], download_url('4.8.42', asset['name']))
    def test_download_failure_never_switches_latest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'VNT_App_4.8.42_Windows_Setup.exe').write_bytes(b'fixture')
            api = Mock()
            api.get_model_files.return_value = []
            with patch('modelscope.hub.api.HubApi', return_value=api), \
                 patch('publish_modelscope.public_json', return_value=None), \
                 patch('publish_modelscope.verify_asset', side_effect=ValueError('hash mismatch')):
                with self.assertRaises(ValueError):
                    publish(root, '4.8.42', 'sha', '')
            api.upload_folder.assert_called_once()
            api.upload_file.assert_not_called()

    def test_latest_changes_only_after_verified_downloads(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'VNT_App_4.8.42_Windows_Setup.exe').write_bytes(b'fixture')
            manifest = manifest_for(root, '4.8.42', 'sha', '')
            api = Mock()
            api.get_model_files.return_value = []
            events = []
            api.upload_folder.side_effect = lambda **kwargs: events.append('assets')
            api.upload_file.side_effect = lambda **kwargs: events.append('latest')
            with patch('modelscope.hub.api.HubApi', return_value=api), \
                 patch('publish_modelscope.public_json', side_effect=[None, manifest]), \
                 patch('publish_modelscope.verify_asset', side_effect=lambda asset: events.append('verified')):
                publish(root, '4.8.42', 'sha', '')
            self.assertEqual(events, ['assets', 'verified', 'latest'])

    def test_missing_installer_or_invalid_version_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            for version in ['4.8.42', '4.8', '../v1']:
                with self.assertRaises(ValueError):
                    manifest_for(Path(temp), version, 'sha', '')

if __name__ == '__main__':
    unittest.main()
