import '../../models/info_block.dart';
import 'block_context.dart';

abstract class BlockHandler {
  Future<InfoBlock?> handle(BlockContext context);
}
