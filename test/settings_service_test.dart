import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:testapp/services/map_service.dart';
import 'package:testapp/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService map tile source', () {
    test('defaults to the OSM.de tile template', () async {
      SharedPreferences.setMockInitialValues({});
      await SettingsService.instance.load();
      expect(
        SettingsService.instance.mapTileUrl.value,
        MapService.defaultTileUrl,
      );
    });

    test('migrates the blocked legacy OSM template to OSM.de', () async {
      SharedPreferences.setMockInitialValues({
        'map_tile_url': MapService.legacyOsmTileUrl,
      });
      await SettingsService.instance.load();
      expect(
        SettingsService.instance.mapTileUrl.value,
        MapService.defaultTileUrl,
      );
    });

    test('keeps a valid custom template', () async {
      const custom = 'https://example.com/tiles/{z}/{x}/{y}.png';
      SharedPreferences.setMockInitialValues({'map_tile_url': custom});
      await SettingsService.instance.load();
      expect(SettingsService.instance.mapTileUrl.value, custom);
    });

    test('replaces invalid saved templates with the default', () async {
      SharedPreferences.setMockInitialValues({
        'map_tile_url': 'https://example.com/no-placeholders',
      });
      await SettingsService.instance.load();
      expect(
        SettingsService.instance.mapTileUrl.value,
        MapService.defaultTileUrl,
      );
    });

    test('persists a valid custom template', () async {
      SharedPreferences.setMockInitialValues({});
      const custom = 'https://example.com/{z}/{x}/{y}.jpg';
      await SettingsService.instance.setMapTileUrl(custom);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('map_tile_url'), custom);
      expect(SettingsService.instance.mapTileUrl.value, custom);
    });
  });
}
