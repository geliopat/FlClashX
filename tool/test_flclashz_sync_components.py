import unittest
from flclashz_sync_components import (
    merge_bytes, require_catalog_review, semver, update_engine,
)


class SyncTests(unittest.TestCase):
    def test_semver(self):
        self.assertLess(semver("v1.9.9"), semver("1.10.0"))
        with self.assertRaises(ValueError):
            semver("v1.2.3-rc1")

    def test_merge_preserves_independent_local_patch(self):
        self.assertEqual(merge_bytes(
            b"a\nb\nc\nd\ne\n", b"local\nb\nc\nd\ne\n",
            b"a\nb\nc\nd\nupstream\n", "strategy.lua"),
            b"local\nb\nc\nd\nupstream\n")

    def test_conflict_is_not_overwritten(self):
        with self.assertRaises(ValueError):
            merge_bytes(b"old\n", b"local\n", b"upstream\n", "strategy.lua")
        with self.assertRaises(ValueError):
            merge_bytes(b"old\n", b"local\n", None, "strategy.lua")

    def test_new_and_removed_files(self):
        self.assertEqual(merge_bytes(None, None, b"new", "new.lua"), b"new")
        self.assertIsNone(merge_bytes(b"old", b"old", None, "old.lua"))

    def test_existing_lua_changes_do_not_require_catalog_rewrite(self):
        require_catalog_review(
            {"zapret-lib.lua": b"old", "imported/kinlay0/README.md": b"old"},
            {"zapret-lib.lua": b"new", "imported/kinlay0/README.md": b"new"},
        )

    def test_catalog_must_match_updated_bat_sources(self):
        path = "imported/kinlay0/example.bat"
        for old, new in [
            ({path: b"old"}, {path: b"new"}),
            ({}, {path: b"new"}),
            ({path: b"old"}, {}),
            ({"imported/kinlay0/translate.py": b"old"},
             {"imported/kinlay0/translate.py": b"new"}),
        ]:
            with self.subTest(old=old, new=new):
                with self.assertRaisesRegex(ValueError, "catalog requires adaptation"):
                    require_catalog_review(old, new)

    def test_added_or_removed_lua_requires_catalog_review(self):
        path = "zapret-new.lua"
        for old, new in [({}, {path: b"new"}), ({path: b"old"}, {})]:
            with self.assertRaises(ValueError):
                require_catalog_review(old, new)

    def test_release_pin(self):
        old = ('$Zapret2Url = "https://github.com/bol-van/zapret2/releases/download/v1.0.8/zapret2-v1.0.8.zip"\n'
               '$Zapret2Sha256 = "' + 'a' * 64 + '"\n'
               'Get-PinnedArchive -Label "bol-van/zapret2 v1.0.8"\n')
        versions = "  'Zapret2': 'v1.0.8',\n"
        release = {"tag_name": "v1.0.9", "draft": False, "prerelease": False,
                   "assets": [{"name": "zapret2-v1.0.9.zip", "size": 10,
                               "digest": "sha256:" + "b" * 64,
                               "browser_download_url": "https://github.com/bol-van/zapret2/releases/download/v1.0.9/zapret2-v1.0.9.zip"}]}
        setup, new, _ = update_engine(old, versions, "Zapret2", release)
        self.assertIn("v1.0.9", setup)
        self.assertIn("b" * 64, setup)
        self.assertIn("'v1.0.9'", new)
        release["assets"][0]["digest"] = None
        with self.assertRaises(ValueError):
            update_engine(old, versions, "Zapret2", release)

    def test_same_version_changed_digest_blocks(self):
        old = ('$FlowsealUrl = "https://github.com/Flowseal/zapret-discord-youtube/releases/download/1.10.4/zapret-discord-youtube-1.10.4.zip"\n'
               '$FlowsealSha256 = "' + 'a' * 64 + '"\n')
        versions = "  'Flowseal': '1.10.4',\n"
        release = {"tag_name": "1.10.4", "assets": [{"name": "zapret-discord-youtube-1.10.4.zip",
                   "size": 10, "digest": "sha256:" + "b" * 64,
                   "browser_download_url": "https://github.com/Flowseal/zapret-discord-youtube/releases/download/1.10.4/zapret-discord-youtube-1.10.4.zip"}]}
        with self.assertRaises(ValueError):
            update_engine(old, versions, "Flowseal", release)


if __name__ == "__main__":
    unittest.main()
