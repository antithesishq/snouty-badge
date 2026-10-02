import contextlib
import io
import os
import shlex
import signal
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from tests.helpers import make_config, make_romfs
from tests.test_station import quiet_net
from badge_manager import device, fat12
from badge_manager.library import Library
from badge_manager.station import DoesNotFit, Station, StationError


class DeploymentSafetyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.badge = self.root / 'badge'
        self.badge.mkdir()
        (self.badge / 'OLD.UF2').write_bytes(b'keep me')
        self.cfg = make_config(self.root, self.badge)
        self.st = Station(self.cfg)
        quiet_net(self.st)
        self.st.poll()

    def tearDown(self):
        self.tmp.cleanup()

    def assert_preserved(self):
        self.assertEqual((self.badge / 'OLD.UF2').read_bytes(), b'keep me')

    def test_missing_and_invalid_source_never_wipe(self):
        source = self.cfg.library / 'carts/snouty.uf2'
        source.unlink()
        with self.assertRaises(DoesNotFit):
            self.st.deploy('demo')
        self.assert_preserved()
        source.write_bytes(b'invalid')
        with self.assertRaises(DoesNotFit):
            self.st.deploy('demo')
        self.assert_preserved()

    def test_copy_uses_validated_snapshot_even_if_library_changes(self):
        source = self.cfg.library / 'carts/snouty.uf2'
        expected = source.read_bytes()
        wipe = self.st._wipe
        def changed_after_preflight(badge):
            source.write_bytes(b'invalid replacement')
            wipe(badge)
        with mock.patch.object(self.st, '_wipe', side_effect=changed_after_preflight):
            self.st.deploy('demo')
        self.assertEqual((self.badge / 'snouty.uf2').read_bytes(), expected)

    def test_invalid_geometry_never_falls_back_to_defaults(self):
        with mock.patch.object(self.st._badge, 'geometry', side_effect=device.DeviceError('bad FAT')):
            with self.assertRaises(DoesNotFit):
                self.st.deploy('demo')
        self.assert_preserved()

    def test_external_manifest_edit_is_refreshed_by_poll(self):
        Library(self.cfg.library).save_set('Another phone', ['snouty'], [])
        self.st.poll()
        self.assertIn('another-phone', self.st.library.sets)

    def test_copy_failure_reports_recovery_and_releases_busy(self):
        with mock.patch.object(self.st._badge, 'copy', side_effect=device.DeviceError('unplugged')):
            with self.assertRaisesRegex(StationError, 'reconnect and deploy again'):
                self.st.deploy('demo')
        self.assertFalse(self.st.status()['busy'])

    def test_missing_sync_script_cannot_bypass_staging(self):
        with mock.patch('badge_manager.station.SYNC_SH', self.root / 'missing-sync.sh'):
            with self.assertRaisesRegex(StationError, 'reinstall'):
                self.st.sync()
        self.assertFalse(self.st.status()['busy'])

    def test_sync_timeout_kills_child_after_shell_leader_exits(self):
        pidfile = self.root / 'child.pid'
        program = ("import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                   f"open({str(pidfile)!r},'w').write(str(os.getpid())); time.sleep(30)")
        command = f'{shlex.quote(sys.executable)} -c {shlex.quote(program)} & exit 0'
        start = time.monotonic()
        try:
            with mock.patch('badge_manager.station.SYNC_TIMEOUT_S', 0.2):
                self.assertEqual(self.st._run_streamed(command), 124)
            self.assertLess(time.monotonic() - start, 3)
            pid = int(pidfile.read_text())
            stat = Path(f'/proc/{pid}/stat')
            self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z')
        finally:
            if pidfile.exists():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), signal.SIGKILL)


class DeviceBoundaryTest(unittest.TestCase):
    def test_directory_and_mounted_copy_reject_paths_and_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            volume = root / 'badge'
            volume.mkdir()
            src = root / 'source'
            src.write_bytes(b'new')
            outside = root / 'outside'
            outside.write_bytes(b'old')
            (volume / 'LINK.GG').symlink_to(outside)
            mounted = device._Mounted(root)
            with mock.patch.object(mounted, 'mount', return_value=volume):
                for adapter in (device.DirBadge(volume), mounted):
                    for name in (str(outside), '../outside', 'a/b', 'a\\b', '.', '..', 'X.', 'X\r', 'LINK.GG'):
                        with self.subTest(adapter=type(adapter).__name__, name=name):
                            with self.assertRaises(device.DeviceError):
                                adapter.copy(src, name)
            self.assertEqual(outside.read_bytes(), b'old')

    def test_volume_label_alone_does_not_select_device(self):
        with mock.patch.object(device, '_by_label', return_value='/dev/notbadge'), mock.patch.object(device, '_by_usb_id', return_value=None):
            self.assertIsNone(device.find_badge())

    def test_multiple_badges_require_disconnect_before_selection(self):
        def paths(pattern):
            return ['/usb/one', '/usb/two'] if pattern == '/usb/*' else []
        def read(path):
            return '1' if path.endswith('/size') else '04d2'
        def walk(path):
            disk = 'sda' if path.endswith('one') else 'sdb'
            return [(path + '/block', [disk], [])]
        with mock.patch.object(device.glob, 'glob', side_effect=paths), \
                mock.patch.object(device, '_read', side_effect=read), \
                mock.patch.object(device.os, 'walk', side_effect=walk):
            with self.assertRaisesRegex(device.DeviceError, 'multiple badges'):
                device._by_usb_id('/usb')

    def test_real_device_mount_requires_identity_label_and_geometry(self):
        badge = device.BlockBadge('/dev/fake')
        with mock.patch.object(device, '_usb_identity', return_value=('1234', '5678')), mock.patch.object(device, '_priv') as run:
            with self.assertRaisesRegex(device.DeviceError, 'identity'):
                badge.mount()
            run.assert_not_called()
        volume = fat12.VolumeInfo(fat12.geometry(), 'WRONG', 1, 1, [])
        with mock.patch.object(device, '_usb_identity', return_value=device.USB_ID), mock.patch.object(badge, '_volume', return_value=volume), mock.patch.object(device, '_priv') as run:
            with self.assertRaisesRegex(device.DeviceError, 'label or geometry'):
                badge.mount()
            run.assert_not_called()


class FatSafetyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.img = Path(self.tmp.name) / 'badge.img'
        self.src = Path(self.tmp.name) / 'a'
        self.src.write_bytes(b'a' * 600)
        with contextlib.redirect_stdout(io.StringIO()):
            make_romfs().main([str(self.img), f'{self.src}=A.GG'])
        self.valid = self.img.read_bytes()

    def tearDown(self):
        self.tmp.cleanup()

    def assert_rejected(self, data):
        self.img.write_bytes(data)
        with self.assertRaises(ValueError):
            fat12.read_volume(io.BytesIO(data))
        with self.assertRaises(ValueError):
            fat12.Fat12Image(str(self.img))
        for call in (device.ImageBadge(self.img).listdir, device.ImageBadge(self.img).wipe):
            with self.assertRaises(device.DeviceError):
                call()
        self.assertEqual(self.img.read_bytes(), data)

    def test_truncated_tables_root_and_data(self):
        for size in (0, 512, 4096, 9000, len(self.valid) - 1):
            with self.subTest(size=size):
                self.assert_rejected(self.valid[:size])

    def test_impossible_geometry(self):
        for offset, fmt, value in ((11, '<H', 0), (13, '<B', 3), (14, '<H', 0),
                                   (16, '<B', 0), (17, '<H', 0), (19, '<H', 2),
                                   (22, '<H', 1)):
            data = bytearray(self.valid)
            struct.pack_into(fmt, data, offset, value)
            with self.subTest(offset=offset):
                self.assert_rejected(data)

    def test_bad_cluster_references_cycles_and_short_chains(self):
        for target in (0, 1, 2, 3000, 0xFF7, 0xFFF):
            data = bytearray(self.valid)
            fat = data[512:9 * 512]
            fat12._fat_set(fat, 2, target)
            data[512:9 * 512] = fat
            with self.subTest(target=target):
                self.assert_rejected(data)
