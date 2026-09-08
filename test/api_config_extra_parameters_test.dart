import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

void main() {
  test('API config persists extra request parameters', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = ApiConfigRepo(db);
    const parameters = [
      ExtraRequestParameter(key: 'reasoning_effort', value: 'xhigh'),
      ExtraRequestParameter(key: 'seed', value: '42', enabled: false),
    ];

    await repo.put(
      const ApiConfig(
        id: 'custom-api',
        name: 'Custom API',
        extraRequestParameters: parameters,
      ),
    );

    final restored = await repo.getById('custom-api');
    expect(restored?.extraRequestParameters, parameters);
  });
}
