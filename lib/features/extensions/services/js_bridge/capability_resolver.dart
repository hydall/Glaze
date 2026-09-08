String readCapabilityForScope(String scope) {
  switch (scope) {
    case 'chat':
      return 'read_chat_vars';
    case 'character':
      return 'read_character_vars';
    case 'global':
      return 'read_global_vars';
    case 'message':
      return 'read_message_vars';
    default:
      return 'read_chat_vars';
  }
}

String writeCapabilityForScope(String scope) {
  switch (scope) {
    case 'chat':
      return 'write_chat_vars';
    case 'character':
      return 'write_character_vars';
    case 'global':
      return 'write_global_vars';
    case 'message':
      return 'write_message_vars';
    default:
      return 'write_chat_vars';
  }
}

String deleteCapabilityForScope(String scope) {
  switch (scope) {
    case 'chat':
      return 'delete_chat_vars';
    case 'character':
      return 'delete_character_vars';
    case 'global':
      return 'delete_global_vars';
    case 'message':
      return 'delete_message_vars';
    default:
      return 'delete_chat_vars';
  }
}
